;;; bongo-player.el --- Music player buffer for Bongo -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Free Software Foundation, Inc.

;; Author: Bongo contributors
;; Keywords: multimedia, hypermedia
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `bongo-player-mode' shows a single, self-contained player buffer for
;; the track playing in Bongo.  The buffer holds, from top to bottom:
;;
;;   - the album cover and the track information,
;;   - the visualizer canvas from `bongo-visualizer',
;;   - a text progress bar with the elapsed and total time,
;;   - a row of widget push-buttons for common actions,
;;   - a fixed viewport of scrolling lyrics.
;;
;; The lyrics do not scroll the window: the player window stays at the
;; top of the buffer and the lyric viewport is redrawn in place.  Within
;; a line, the first line's `line-height' is grown by a fraction of a
;; line so the text slides up smoothly until the next line becomes the
;; current one.
;;
;; Usage:
;;
;;   (require 'bongo-player)
;;   (bongo-player-mode 1)
;;
;; The mode enables the `bongo-lyrics' engine and follows whichever
;; Bongo playlist buffer currently has an active player.

;;; Code:

(require 'bongo)
(require 'bongo-lyrics)
(require 'bongo-visualizer)
(require 'cl-lib)
(require 'subr-x)
(require 'wid-edit)


;;;; Customization

(defgroup bongo-player nil
  "Music player buffer for Bongo."
  :group 'bongo
  :prefix "bongo-player-")

(defface bongo-player-title
  '((t :inherit variable-pitch :weight bold))
  "Face for the track title in the player buffer."
  :group 'bongo-player)

(defface bongo-player-info
  '((t :inherit shadow))
  "Face for the artist, album and time information."
  :group 'bongo-player)

(defface bongo-player-inactive
  '((t :inherit shadow))
  "Face for status messages shown in place of lyrics."
  :group 'bongo-player)

(defface bongo-player-lyrics-current
  '((t :inherit highlight :extend t))
  "Face for the lyric line that is currently playing."
  :group 'bongo-player)

(defface bongo-player-lyrics-instrumental
  '((t :inherit shadow :slant italic))
  "Face for instrumental passages in the lyrics."
  :group 'bongo-player)

(defface bongo-player-progress-empty
  '((t :inherit shadow))
  "Face for the unsung part of the progress bar."
  :group 'bongo-player)

(defface bongo-player-progress-track
  '((t :foreground "#a06aa8"))
  "Face for the elapsed part of the progress bar."
  :group 'bongo-player)

(defface bongo-player-progress-current
  '((t :foreground "#e26aa2" :weight bold))
  "Face for the part of the progress bar covered by the current line."
  :group 'bongo-player)

(defcustom bongo-player-buffer-name "*Bongo Player*"
  "Name of the player buffer."
  :type 'string
  :group 'bongo-player)

(defcustom bongo-player-side 'bottom
  "Side used to display the player window.
One of `bottom', `top', `left' or `right'."
  :type '(choice (const bottom) (const top) (const left) (const right))
  :group 'bongo-player)

(defcustom bongo-player-window-height 26
  "Height in lines of the player side window.
Make this large enough for the header (cover, visualizer, progress
bar and controls) plus `bongo-player-lyrics-lines' lyric lines."
  :type 'integer
  :group 'bongo-player)

(defcustom bongo-player-lyrics-lines 7
  "Number of lyric lines shown in the player buffer."
  :type 'integer
  :group 'bongo-player)

(defcustom bongo-player-smooth-scroll t
  "Whether to slide the lyrics by fractions of a line.
When nil, the lyrics jump from line to line instead."
  :type 'boolean
  :group 'bongo-player)

(defcustom bongo-player-progress-width nil
  "Width of the progress bar in columns.
A value of nil means use the width of the player window, leaving
room for the time display."
  :type '(choice (const :tag "Window width" nil) integer)
  :group 'bongo-player)

(defcustom bongo-player-show-cover t
  "Whether to show the album cover in the player buffer."
  :type 'boolean
  :group 'bongo-player)

(defcustom bongo-player-cover-max-size 140
  "Maximum width and height of the album cover, in pixels."
  :type 'integer
  :group 'bongo-player)

(defcustom bongo-player-cover-directory
  (locate-user-emacs-file "bongo-player/")
  "Directory where covers extracted from track tags are cached."
  :type 'directory
  :group 'bongo-player)

(defcustom bongo-player-ffmpeg-program "ffmpeg"
  "Program used to extract cover art embedded in a track."
  :type 'string
  :group 'bongo-player)

(defcustom bongo-player-show-visualizer t
  "Whether to show the Bongo visualizer in the player buffer."
  :type 'boolean
  :group 'bongo-player)


;;;; State

(defvar bongo-player--buffer nil
  "The player buffer, or nil.")

(defvar bongo-player--window nil
  "Window displaying the player buffer, or nil.")

(defvar bongo-player--header-end nil
  "Marker at the end of the player header.")

(defvar bongo-player--progress-start nil
  "Marker at the start of the progress line.")

(defvar bongo-player--progress-end nil
  "Marker at the end of the progress line.")

(defvar bongo-player--lyrics-start nil
  "Marker at the start of the lyrics region.")

(defvar bongo-player--spacer nil
  "Marker on the newline of the first rendered lyric line.")

(defvar bongo-player--spacer-height nil
  "Natural pixel height of the first rendered lyric line.")

(defvar bongo-player--spacer-value nil
  "Height spec last written to the first lyric line's newline.")

(defvar bongo-player--current-line nil
  "Marker at the current lyric line, or nil.")

(defvar bongo-player--rendered-index nil
  "Lyric index currently rendered in the buffer.")

(defvar bongo-player--last-track nil
  "Track key the buffer was last rendered for.")

(defvar bongo-player--dirty t
  "Non-nil when the player buffer must be fully redrawn.")

(defvar bongo-player--cover-file nil
  "File name of the current cover image, or nil.")

(defvar bongo-player--cover nil
  "Image object of the current cover, or nil.")

(defvar bongo-player--canvas nil
  "Visualizer canvas shown in the player buffer, or nil.")

(defvar bongo-player--canvas-owner nil
  "Non-nil when the player created the visualizer canvas itself.")

(defvar bongo-player--visualizer-mode-was-on nil
  "Non-nil when the player disabled `bongo-visualizer-mode'.")

(defvar bongo-player--visualizer-timer nil
  "Timer driving the visualizer while the player owns the canvas.")

(defvar bongo-player--enabled-lyrics nil
  "Non-nil when `bongo-player-mode' enabled the lyrics engine.")

(defvar bongo-player-mode)


;;;; Mouse and key bindings

(defvar bongo-player-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'bongo-player-seek-clicked-line)
    (define-key map (kbd "RET") #'bongo-player-seek-current-line)
    map)
  "Keymap used on lyric lines in the player buffer.")

(defvar bongo-player-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'bongo-player-refresh)
    (define-key map (kbd "f") #'bongo-lyrics-load-file)
    (define-key map (kbd "F") #'bongo-lyrics-forget)
    (define-key map (kbd "+") #'bongo-lyrics-offset-later)
    (define-key map (kbd "-") #'bongo-lyrics-offset-earlier)
    (define-key map (kbd "0") #'bongo-lyrics-reset-offset)
    map)
  "Keymap used in the player buffer.")

(define-derived-mode bongo-player-view-mode special-mode "Bongo-Player"
  "Major mode for the Bongo player buffer.

\\{bongo-player-view-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format '(:eval (bongo-player--mode-line))))


;;;; Buffer and window helpers

(defun bongo-player--buffer ()
  "Return the live player buffer, or nil."
  (and (buffer-live-p bongo-player--buffer) bongo-player--buffer))

(defun bongo-player--window ()
  "Return the live player window, or nil."
  (and (window-live-p bongo-player--window)
       (eq (window-buffer bongo-player--window) bongo-player--buffer)
       bongo-player--window))

(defun bongo-player--mode-line ()
  "Return the player mode line construct."
  (concat " " (let ((title (bongo-lyrics-title)))
               (if (string-empty-p title) "Bongo Player" title))
          (when (/= bongo-lyrics-offset 0.0)
            (format " [%+g s]" bongo-lyrics-offset))))


;;;; Album cover

(defun bongo-player--local-cover (file)
  "Return a cover image next to FILE, or nil."
  (when (and (stringp file)
             (not (bongo-uri-p file))
             (file-name-absolute-p file))
    (let ((directory (file-name-directory file))
          (base (downcase (file-name-base file)))
          (names '("cover" "folder" "front" "album" "albumart")))
      (when (file-directory-p directory)
        (cl-find-if
         (lambda (candidate)
           (and (member (downcase (file-name-base candidate))
                        (cons base names))
                (string-match-p "\\.\\(?:jpe?g\\|png\\|webp\\|gif\\)\\'"
                                candidate)))
         (directory-files directory t))))))

(defun bongo-player--embedded-cover (key)
  "Extract cover art embedded in the track described by KEY, or nil."
  (let* ((file (nth 0 key))
         (cache (expand-file-name
                 (concat (md5 (format "%S" key)) ".png")
                 bongo-player-cover-directory)))
    (cond
     ((file-readable-p cache)
      cache)
     ((and (stringp file)
           (file-readable-p file)
           (not (bongo-uri-p file))
           (executable-find bongo-player-ffmpeg-program))
      (make-directory (file-name-directory cache) t)
      (when (zerop (or (ignore-errors
                         (call-process bongo-player-ffmpeg-program
                                       nil nil nil
                                       "-y" "-v" "error"
                                       "-i" file
                                       "-map" "0:v" "-map" "-0:V"
                                       "-frames:v" "1"
                                       cache))
                       1))
        (and (file-readable-p cache) cache))))))

(defun bongo-player--cover-file (key)
  "Return a cover image file for the track described by KEY, or nil."
  (and key
       (or (bongo-player--local-cover (nth 0 key))
           (bongo-player--embedded-cover key))))

(defun bongo-player--create-cover (file)
  "Return a cover image object for FILE, or nil."
  (when file
    (ignore-errors
      (create-image file nil nil
                    :max-width bongo-player-cover-max-size
                    :max-height bongo-player-cover-max-size
                    :ascent 'center))))

(defun bongo-player--load-cover (track)
  "Find and load the cover for the track described by TRACK."
  (setq bongo-player--cover-file nil
        bongo-player--cover nil)
  (when (and bongo-player-show-cover track)
    (let ((file (bongo-player--cover-file track)))
      (when file
        (setq bongo-player--cover-file file
              bongo-player--cover (bongo-player--create-cover file))))))


;;;; Visualizer

(defun bongo-player--setup-visualizer ()
  "Create the visualizer canvas shown in the player buffer.
When `bongo-visualizer-mode' is enabled, it is temporarily disabled
so that the player can own a full-size canvas; the mode is restored
when the player is turned off."
  (when (and bongo-player-show-visualizer
             (fboundp 'bongo-visualizer-render-frame))
    (setq bongo-player--visualizer-mode-was-on
          (and (bound-and-true-p bongo-visualizer-mode) t))
    (when bongo-player--visualizer-mode-was-on
      (bongo-visualizer-mode -1))
    (let ((bongo-visualizer-display 'buffer))
      (bongo-visualizer--setup-canvas))
    (setq bongo-player--canvas bongo-visualizer--canvas
          bongo-player--canvas-owner t
          bongo-player--visualizer-timer
          (run-with-timer 0 (/ 1.0 (max 1 bongo-visualizer-fps))
                          #'bongo-player--visualizer-tick))))

(defun bongo-player--sync-canvas ()
  "Notice a visualizer canvas replaced by a theme change."
  (when (and bongo-player--canvas
             (not (eq bongo-player--canvas bongo-visualizer--canvas)))
    (setq bongo-player--canvas bongo-visualizer--canvas
          bongo-player--dirty t)))

(defun bongo-player--visualizer-tick ()
  "Render one visualizer frame for the player buffer."
  (when (and bongo-player-mode bongo-player--canvas)
    (ignore-errors (bongo-visualizer-render-frame))
    (bongo-player--sync-canvas)))

(defun bongo-player--teardown-visualizer ()
  "Release the visualizer resources held by the player."
  (when bongo-player--visualizer-timer
    (cancel-timer bongo-player--visualizer-timer)
    (setq bongo-player--visualizer-timer nil))
  (when (and bongo-player--canvas bongo-player--canvas-owner)
    (ignore-errors (bongo-visualizer--stop-pcm))
    (image-flush bongo-player--canvas t))
  (setq bongo-player--canvas nil
        bongo-player--canvas-owner nil)
  (when bongo-player--visualizer-mode-was-on
    (setq bongo-player--visualizer-mode-was-on nil)
    (bongo-visualizer-mode 1)))


;;;; The progress bar

(defconst bongo-player--progress-blocks
  ["\u258f" "\u258e" "\u258d" "\u258c" "\u258b" "\u258a" "\u2589" "\u2588"]
  "Fractional block characters used to draw the progress bar.")

(defun bongo-player--progress-columns ()
  "Return the width in columns of the progress bar."
  (or bongo-player-progress-width
      (let ((window (bongo-player--window)))
        (and window (max 8 (- (window-body-width window) 16))))
      40))

(defun bongo-player--progress-string ()
  "Return the progress line: a text bar and the elapsed/total time."
  (let* ((player (bongo-lyrics-live-player))
         (total (bongo-lyrics-total-time))
         (elapsed (bongo-lyrics-elapsed-time))
         (index (bongo-lyrics-current-index))
         (entries (bongo-lyrics-timed-lines))
         (width (bongo-player--progress-columns))
         (has-line (and entries index))
         (position (cond
                    ((null player) 0.0)
                    ((and total (> total 0.0))
                     (max 0.0 (min 1.0 (/ elapsed total))))
                    (has-line
                     (bongo-lyrics-current-fraction))
                    (t 0.0)))
         (line-start (if (and has-line total (> total 0.0))
                         (max 0.0
                              (min 1.0
                                   (/ (car (aref entries index)) total)))
                       0.0))
         (cells nil))
    (dotimes (i width)
      (let* ((low (/ (float i) width))
             (high (/ (float (1+ i)) width))
             (middle (/ (+ low high) 2.0))
             (fill (max 0.0 (min 1.0 (/ (- position low) (- high low)))))
             (face (cond
                    ((<= fill 0.0) 'bongo-player-progress-empty)
                    ((and has-line (>= middle line-start))
                     'bongo-player-progress-current)
                    (t 'bongo-player-progress-track))))
        (push (propertize
               (cond
                ((<= fill 0.0) "\u2591")
                ((>= fill 1.0) "\u2588")
                (t (aref bongo-player--progress-blocks
                         (1- (max 1 (min 8 (ceiling (* fill 8))))))))
               'face face)
              cells)))
    (concat (apply #'concat (nreverse cells))
            " "
            (propertize
             (if (and total (> total 0.0))
                 (format "%s / %s"
                         (bongo-format-seconds elapsed)
                         (bongo-format-seconds total))
               (bongo-format-seconds elapsed))
             'face 'bongo-player-info))))

(defun bongo-player--update-progress ()
  "Redraw the progress line in place."
  (let ((inhibit-read-only t)
        (start (and (markerp bongo-player--progress-start)
                    (marker-position bongo-player--progress-start)))
        (end (and (markerp bongo-player--progress-end)
                  (marker-position bongo-player--progress-end))))
    (when (and start end (<= start end))
      (save-excursion
        (delete-region start end)
        (goto-char start)
        (insert (bongo-player--progress-string))
        (set-marker bongo-player--progress-end (point)
                    bongo-player--buffer)))))

(defun bongo-player--insert-controls ()
  "Insert the widget control row."
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                           (bongo-lyrics-offset-earlier))
                 " -0.5s ")
  (insert " ")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                           (bongo-lyrics-offset-later))
                 " +0.5s ")
  (insert " ")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                           (bongo-lyrics-reset-offset))
                 " 0 ")
  (insert "  ")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                           (call-interactively #'bongo-lyrics-load-file))
                 " Load file ")
  (insert " ")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                           (bongo-lyrics-reload))
                 " Reload ")
  (insert " ")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                           (bongo-lyrics-forget))
                 " Forget ")
  (widget-setup))


;;;; Rendering

(defun bongo-player--render-header ()
  "Redraw the header of the player buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (delete-region (point-min)
                   (if (marker-position bongo-player--header-end)
                       (marker-position bongo-player--header-end)
                     (point-min)))
    (goto-char (point-min))
    (insert (propertize (let ((title (bongo-lyrics-title)))
                          (if (string-empty-p title) "Bongo Player" title))
                        'face 'bongo-player-title))
    (insert "\n")
    (let ((info (string-join
                 (delq nil (list (nth 1 bongo-player--last-track)
                                 (nth 3 bongo-player--last-track)))
                 " \u2014 ")))
      (unless (string-empty-p info)
        (insert (propertize info 'face 'bongo-player-info))
        (insert "\n")))
    (let ((cover bongo-player--cover)
          (canvas bongo-player--canvas))
      (when (or cover canvas)
        (when cover
          (insert-image cover " "))
        (when (and cover canvas)
          (insert "   "))
        (when canvas
          (insert (propertize " " 'display canvas)))
        (insert "\n")))
    (set-marker bongo-player--progress-start (point))
    (insert (bongo-player--progress-string))
    (set-marker bongo-player--progress-end (point) bongo-player--buffer)
    (insert "\n")
    (bongo-player--insert-controls)
    (insert "\n\n")
    (set-marker bongo-player--header-end (point) bongo-player--buffer)
    (set-marker bongo-player--lyrics-start (point) bongo-player--buffer)))

(defun bongo-player--insert-message (message)
  "Insert MESSAGE in place of lyrics."
  (insert (propertize (or message "No lyrics")
                      'face 'bongo-player-inactive)
          "\n"))

(defun bongo-player--insert-lyric-line (index text current)
  "Insert the lyric line TEXT for INDEX.
When CURRENT is non-nil, highlight the line."
  (let* ((empty (string-empty-p (string-trim text)))
         (display (if empty "\u266a" text))
         (face (cond (current 'bongo-player-lyrics-current)
                     (empty 'bongo-player-lyrics-instrumental)
                     (t nil))))
    (insert (propertize display
                        'face face
                        'bongo-player-index index
                        'keymap bongo-player-line-map
                        'mouse-face 'highlight)
            "\n")))

(defun bongo-player--line-height (start end)
  "Return the pixel height of the text between START and END."
  (let ((window (bongo-player--window)))
    (or (and window
             (cdr (ignore-errors
                    (window-text-pixel-size window start end))))
        (frame-char-height (if window
                               (window-frame window)
                             (selected-frame))))))

(defun bongo-player--insert-timed-lyrics (entries)
  "Insert a viewport of lyrics around the current line of ENTRIES."
  (let* ((count (length entries))
         (visible (max 1 bongo-player-lyrics-lines))
         (half (/ (1- visible) 2))
         (index (or (bongo-lyrics-current-index) 0))
         (start (max 0 (- index (1- half))))
         (end (min count (+ start visible)))
         (first t))
    (setq bongo-player--current-line nil)
    (cl-loop for i from start below end
             for text = (cdr (aref entries i))
             for current = (eql i (bongo-lyrics-current-index))
             do (let ((line-start (point)))
                  (bongo-player--insert-lyric-line i text current)
                  (when first
                    (setq first nil
                          bongo-player--spacer
                          (copy-marker (1- (point)) nil)
                          bongo-player--spacer-height
                          (bongo-player--line-height line-start (point))))
                  (when current
                    (setq bongo-player--current-line
                          (copy-marker line-start nil)))))))

(defun bongo-player--render-lyrics ()
  "Redraw the lyrics region of the player buffer."
  (let ((inhibit-read-only t)
        (start (marker-position bongo-player--lyrics-start)))
    (when start
      (delete-region start (point-max))
      (goto-char start)
      (setq bongo-player--spacer nil
            bongo-player--spacer-height nil
            bongo-player--spacer-value nil
            bongo-player--current-line nil)
      (if (eq (bongo-lyrics-status) 'ok)
          (let ((entries (bongo-lyrics-timed-lines)))
            (cond
             (entries
              (bongo-player--insert-timed-lyrics entries))
             ((bongo-lyrics-plain-lines)
              (dolist (line (bongo-lyrics-plain-lines))
                (insert line "\n")))
             (t
              (bongo-player--insert-message "No lyrics available."))))
        (bongo-player--insert-message (bongo-lyrics-message))))))

(defun bongo-player--update-spacer ()
  "Slide the lyrics according to the current line fraction."
  (let ((marker bongo-player--spacer))
    (when (and (markerp marker) (marker-position marker))
      (let* ((window (bongo-player--window))
             (frame (if window (window-frame window) (selected-frame)))
             (char-height (max 1 (frame-char-height frame)))
             (height (or bongo-player--spacer-height char-height))
             (fraction (if bongo-player-smooth-scroll
                           (bongo-lyrics-current-fraction)
                         0.0))
             (total (/ (+ height (* (- 1.0 fraction) height))
                       (float char-height)))
             (position (marker-position marker)))
        (unless (equal total bongo-player--spacer-value)
          (setq bongo-player--spacer-value total)
          (put-text-property position (1+ position) 'line-height total)
          (when window
            (force-window-update window)))))))

(defun bongo-player--content-fits-p (window)
  "Return non-nil when the whole player buffer fits in WINDOW."
  (let ((buffer-height (cdr (ignore-errors
                              (window-text-pixel-size
                               window (point-min) (point-max)
                               nil nil nil t))))
        (window-height (window-body-height window t)))
    (or (null buffer-height)
        (<= buffer-height window-height))))

(defun bongo-player--place-window ()
  "Keep the header visible, or scroll to the lyrics when too tall."
  (let ((window (bongo-player--window)))
    (when window
      (let* ((lyrics (marker-position bongo-player--lyrics-start))
             (start (if (or (null lyrics)
                            (bongo-player--content-fits-p window))
                        (point-min)
                      lyrics)))
        (unless (eq window (selected-window))
          (set-window-point window
                            (or (and (markerp bongo-player--current-line)
                                     (marker-position bongo-player--current-line))
                                lyrics
                                (point-min))))
        (set-window-start window start t)))))


;;;; The update loop

(defun bongo-player--content-changed ()
  "Note that the lyrics content or status changed."
  (setq bongo-player--dirty t))

(defun bongo-player--update ()
  "Refresh the player buffer from the lyrics engine."
  (when (and bongo-player-mode (buffer-live-p bongo-player--buffer))
    (with-current-buffer bongo-player--buffer
      (let ((track (bongo-lyrics-track-key))
            (index (bongo-lyrics-current-index))
            (inhibit-read-only t))
        (bongo-player--sync-canvas)
        (when (or bongo-player--dirty
                  (not (equal track bongo-player--last-track)))
          (setq bongo-player--dirty nil
                bongo-player--last-track track)
          (bongo-player--load-cover track)
          (bongo-player--render-header)
          (bongo-player--render-lyrics)
          (setq bongo-player--rendered-index index))
        (bongo-player--update-progress)
        (unless (eql index bongo-player--rendered-index)
          (setq bongo-player--rendered-index index)
          (bongo-player--render-lyrics))
        (bongo-player--update-spacer)
        (bongo-player--place-window)))))


;;;; Commands

(defun bongo-player-refresh ()
  "Reload the lyrics of the current track."
  (interactive)
  (bongo-lyrics-reload))

(defun bongo-player-seek-clicked-line (event)
  "Seek to the lyric line clicked with EVENT."
  (interactive "e")
  (let* ((position (event-start event))
         (point (posn-point position))
         (index (and point (get-text-property point 'bongo-player-index))))
    (when (integerp index)
      (ignore-errors (bongo-lyrics-seek-to-index index)))))

(defun bongo-player-seek-current-line ()
  "Seek to the lyric line at point."
  (interactive)
  (let ((index (get-text-property (point) 'bongo-player-index)))
    (when (integerp index)
      (ignore-errors (bongo-lyrics-seek-to-index index)))))


;;;; The global minor mode

(defun bongo-player--setup-buffer ()
  "Create and display the player buffer."
  (setq bongo-player--buffer (get-buffer-create bongo-player-buffer-name))
  (with-current-buffer bongo-player--buffer
    (unless (derived-mode-p 'bongo-player-view-mode)
      (bongo-player-view-mode))
    (let ((inhibit-read-only t))
      (erase-buffer))
    (setq-local mode-line-format '(:eval (bongo-player--mode-line)))
    (setq bongo-player--header-end (copy-marker (point-min)))
    (setq bongo-player--progress-start (copy-marker (point-min)))
    (setq bongo-player--progress-end (copy-marker (point-min)))
    (setq bongo-player--lyrics-start (copy-marker (point-min)))
    (setq bongo-player--spacer nil
          bongo-player--spacer-height nil
          bongo-player--spacer-value nil
          bongo-player--current-line nil))
  (unless (bongo-player--window)
    (setq bongo-player--window
          (display-buffer
           bongo-player--buffer
           `(display-buffer-in-side-window
             (side . ,bongo-player-side)
             (slot . 0)
             (window-height . ,bongo-player-window-height))))))

(defun bongo-player--teardown-buffer ()
  "Remove the player buffer and its window."
  (when (window-live-p bongo-player--window)
    (ignore-errors (delete-window bongo-player--window)))
  (let ((buffer (bongo-player--buffer)))
    (when buffer
      (kill-buffer buffer)))
  (setq bongo-player--buffer nil
        bongo-player--window nil
        bongo-player--header-end nil
        bongo-player--progress-start nil
        bongo-player--progress-end nil
        bongo-player--lyrics-start nil
        bongo-player--spacer nil
        bongo-player--spacer-height nil
        bongo-player--spacer-value nil
        bongo-player--current-line nil
        bongo-player--rendered-index nil
        bongo-player--last-track nil
        bongo-player--cover-file nil
        bongo-player--cover nil
        bongo-player--dirty t))

;;;###autoload
(define-minor-mode bongo-player-mode
  "Toggle the Bongo player buffer.
The buffer shows the album cover, the visualizer, a progress bar and
scrolling lyrics for the track that Bongo is playing.  This is a
global minor mode; it follows whichever Bongo playlist buffer
currently has an active player."
  :global t
  :group 'bongo-player
  (if bongo-player-mode
      (progn
        (bongo-player--setup-visualizer)
        (bongo-player--setup-buffer)
        (add-hook 'bongo-lyrics-update-functions #'bongo-player--update)
        (add-hook 'bongo-lyrics-changed-hook #'bongo-player--content-changed)
        (unless bongo-lyrics-mode
          (bongo-lyrics-mode 1)
          (setq bongo-player--enabled-lyrics t))
        (setq bongo-player--dirty t)
        (bongo-player--update))
    (remove-hook 'bongo-lyrics-update-functions #'bongo-player--update)
    (remove-hook 'bongo-lyrics-changed-hook #'bongo-player--content-changed)
    (bongo-player--teardown-visualizer)
    (when bongo-player--enabled-lyrics
      (setq bongo-player--enabled-lyrics nil)
      (bongo-lyrics-mode -1))
    (bongo-player--teardown-buffer)))

(provide 'bongo-player)
;;; bongo-player.el ends here
