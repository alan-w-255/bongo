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
;; the track playing in Bongo.  The layout is:
;;
;;   - the buffer header line holds the track title on the left and a
;;     row of widget push-buttons for common actions on the right,
;;   - the buffer body holds the track information, the visualizer
;;     canvas and a fixed viewport of scrolling lyrics,
;;   - the buffer mode line holds the progress bar, drawn as a canvas
;;     image with the elapsed and total time.  The progress bar is
;;     buffer-local, so it only appears in the player buffer.
;;
;; Widget buttons need buffer text to live in, which a header line
;; cannot provide; they are rendered with the widget faces and their
;; clicks are dispatched through a keymap attached to the header line.
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

(defcustom bongo-player-window-height 26
  "Height in lines of the player window.
Make this large enough for the header (visualizer and progress bar)
plus `bongo-player-lyrics-lines' lyric lines."
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

(defcustom bongo-player-progress-bar t
  "Whether to show a progress bar in the player mode line.
The bar is a canvas image and only appears in the player buffer."
  :type 'boolean
  :group 'bongo-player)

(defcustom bongo-player-progress-height nil
  "Height in pixels of the mode line progress bar.
A value of nil falls back to `bongo-visualizer-mode-line-height',
and to the height of the mode line when that is nil too."
  :type '(choice (const :tag "Mode line height" nil) integer)
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

(defvar bongo-player--lyrics-start nil
  "Marker at the start of the lyrics region.")

(defvar bongo-player--header-buttons nil
  "Cached button string of the player header line.")

(defvar bongo-player--progress-canvas nil
  "Canvas image drawn in the mode line of the player buffer.")

(defvar bongo-player--progress-data nil
  "ARGB32 pixel vector of `bongo-player--progress-canvas'.")

(defvar bongo-player--progress-canvas-width nil
  "Width in pixels of `bongo-player--progress-canvas'.")

(defvar bongo-player--progress-canvas-height nil
  "Height in pixels of `bongo-player--progress-canvas'.")

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
  (setq-local mode-line-format '(:eval (bongo-player--mode-line)))
  (setq-local header-line-format '(:eval (bongo-player--header-line))))


;;;; Buffer and window helpers

(defun bongo-player--buffer ()
  "Return the live player buffer, or nil."
  (and (buffer-live-p bongo-player--buffer) bongo-player--buffer))

(defun bongo-player--window ()
  "Return the live player window, or nil."
  (and (window-live-p bongo-player--window)
       (eq (window-buffer bongo-player--window) bongo-player--buffer)
       bongo-player--window))

(defun bongo-player--progress-label ()
  "Return the right-aligned label shown after the progress bar.
It holds the lyrics offset when there is one, and the elapsed and
total time of the current track."
  (let ((total (bongo-lyrics-total-time))
        (elapsed (or (bongo-lyrics-elapsed-time) 0.0))
        (offset bongo-lyrics-offset))
    (concat (when (/= offset 0.0)
              (format "[%+g s] " offset))
            (if (and total (> total 0.0))
                (format "%s / %s"
                        (bongo-format-seconds elapsed)
                        (bongo-format-seconds total))
              (bongo-format-seconds elapsed)))))

(defun bongo-player--string-pixel-width (string &optional face)
  "Return the pixel width of STRING as it is shown with FACE."
  (let ((probe (copy-sequence string)))
    (when face
      (add-face-text-property 0 (length probe) face t probe))
    (string-pixel-width probe (bongo-player--buffer))))

(defun bongo-player--mode-line ()
  "Return the player mode line construct.
The progress bar is a canvas image; the elapsed and total time are
right-aligned after it."
  (let* ((time (bongo-player--progress-label))
         (time-width (bongo-player--string-pixel-width time 'mode-line)))
    (concat
     " "
     (when (and bongo-player-progress-bar bongo-player--progress-canvas)
       (propertize " " 'display bongo-player--progress-canvas
                   'help-echo "Playback position"))
     (propertize " " 'display
                 `(space :align-to (- right (,(+ time-width 4)))))
     time
     " ")))


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


;;;; The header line buttons

(defvar bongo-player-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'bongo-player-header-click)
    (define-key map [header-line down-mouse-1] #'ignore)
    map)
  "Keymap used on the buttons in the player header line.")

(defun bongo-player-header-click (event)
  "Invoke the header line button clicked with EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (object (posn-object start))
         (action (cond
                  ((consp object)
                   (get-text-property (cdr object)
                                      'bongo-player-action
                                      (car object)))
                  ((integer-or-marker-p (posn-point start))
                   (with-current-buffer (window-buffer (posn-window start))
                     (get-char-property (posn-point start)
                                        'bongo-player-action))))))
    (when (commandp action)
      (call-interactively action))))

(defun bongo-player--widget-string (type &rest args)
  "Render widget TYPE with ARGS and return it as a string.
Widgets store their faces, help and button properties in overlays,
which a header line cannot display, so the properties that matter
are copied over to text properties."
  (with-temp-buffer
    (apply #'widget-create type args)
    (widget-setup)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (let ((start (- (overlay-start overlay) (point-min)))
              (end (- (overlay-end overlay) (point-min))))
          (dolist (property '(face mouse-face help-echo))
            (let ((value (overlay-get overlay property)))
              (when value
                (add-text-properties start end
                                     (list property value)
                                     text))))))
      text)))

(defun bongo-player--header-button (label action &optional help)
  "Return a header line button string labelled LABEL for ACTION.
HELP is the tooltip shown when the mouse is over the button."
  (let ((text (bongo-player--widget-string
               'push-button
               :notify (lambda (&rest _) (call-interactively action))
               :help-echo help
               label)))
    (add-text-properties 0 (length text)
                         (list 'keymap bongo-player-header-map
                               'pointer 'hand
                               'bongo-player-action action)
                         text)
    text))

(defun bongo-player--header-buttons ()
  "Return the button string shown on the right of the header line."
  (or bongo-player--header-buttons
      (setq bongo-player--header-buttons
            (mapconcat
             #'identity
             (list
              (bongo-player--header-button
               " -0.5s " #'bongo-lyrics-offset-earlier
               "Make the lyrics appear earlier")
              (bongo-player--header-button
               " +0.5s " #'bongo-lyrics-offset-later
               "Make the lyrics appear later")
              (bongo-player--header-button
               " 0 " #'bongo-lyrics-reset-offset
               "Reset the lyrics offset")
              (bongo-player--header-button
               " Load file " #'bongo-lyrics-load-file
               "Pick a lyrics file")
              (bongo-player--header-button
               " Reload " #'bongo-lyrics-reload
               "Reload the lyrics")
              (bongo-player--header-button
               " Forget " #'bongo-lyrics-forget
               "Forget the cached lyrics"))
             " "))))

(defun bongo-player--header-line ()
  "Return the header line construct for the player buffer.
The track title is shown on the left and the widget buttons are
right-aligned.  The title is truncated when the window is too
narrow to hold both."
  (let* ((window (bongo-player--window))
         (frame (if window (window-frame window) (selected-frame)))
         (available (if window (window-body-width window t) 400))
         (right (bongo-player--header-buttons))
         (right-width (bongo-player--string-pixel-width right 'header-line))
         (left (concat
                " "
                (propertize (let ((title (bongo-lyrics-title)))
                              (if (string-empty-p title)
                                  "Bongo Player"
                                title))
                            'face 'bongo-player-title)))
         (left (truncate-string-pixelwise
                left (max 0 (- available right-width 8
                               (frame-char-width frame)))
                (bongo-player--buffer) "\u2026")))
    (concat left
            (propertize " " 'display
                        `(space :align-to (- right (,(+ right-width 8)))))
            right
            " ")))


;;;; The mode line progress bar

(defun bongo-player--progress-height ()
  "Return the pixel height of the mode line progress canvas."
  (let* ((window (bongo-player--window))
         (height (and window
                      (fboundp 'window-mode-line-height)
                      (window-mode-line-height window))))
    (or (and (integerp bongo-player-progress-height)
             (> bongo-player-progress-height 1)
             bongo-player-progress-height)
        (and (integerp bongo-visualizer-mode-line-height)
             (> bongo-visualizer-mode-line-height 1)
             bongo-visualizer-mode-line-height)
        (and (integerp height) (> height 1) height)
        (frame-char-height (if window
                               (window-frame window)
                             (selected-frame))))))

(defun bongo-player--progress-width ()
  "Return the pixel width of the mode line progress canvas."
  (let* ((window (bongo-player--window))
         (frame (if window (window-frame window) (selected-frame)))
         (char-width (max 1 (frame-char-width frame)))
         (available (if window (window-body-width window t) 400))
         (time (bongo-player--progress-label))
         (time-width (bongo-player--string-pixel-width time 'mode-line))
         ;; Room for the spaces around the bar, the time and a margin.
         (reserved (+ (* 3 char-width) time-width 6)))
    (max 40 (- available reserved))))

(defun bongo-player--face-color (face attribute &optional alpha)
  "Return FACE's ATTRIBUTE color packed into ARGB32.
ATTRIBUTE is a face attribute such as :foreground or :background.
ALPHA is the alpha byte of the packed color, opaque by default."
  (let ((color (face-attribute face attribute nil t)))
    (if (stringp color)
        (let ((values (color-values color)))
          (if values
              (bongo-visualizer--argb
               (/ (float (nth 0 values)) 257.0)
               (/ (float (nth 1 values)) 257.0)
               (/ (float (nth 2 values)) 257.0)
               alpha)
            #xffffffff))
      #xffffffff)))

(defun bongo-player--mode-line-face ()
  "Return the mode line face used by the player window."
  (let ((window (bongo-player--window)))
    (if (and window (eq window (selected-window)))
        'mode-line
      'mode-line-inactive)))

(defun bongo-player--create-progress-canvas (width height)
  "Create the mode line progress canvas of WIDTH by HEIGHT pixels."
  (when bongo-player--progress-canvas
    (image-flush bongo-player--progress-canvas t))
  (let ((data (make-vector (* width height)
                           (bongo-visualizer--argb 0 0 0 0))))
    (setq bongo-player--progress-canvas
          (create-image data 'canvas t
                        :data-width width
                        :data-height height
                        :ascent 'center)
          bongo-player--progress-canvas-width width
          bongo-player--progress-canvas-height height
          bongo-player--progress-data
          (plist-get (cdr bongo-player--progress-canvas) :data))))

(defun bongo-player--paint-progress-canvas ()
  "Paint the current playback position into the progress canvas."
  (let* ((data bongo-player--progress-data)
         (width bongo-player--progress-canvas-width)
         (height bongo-player--progress-canvas-height))
    (when (and data width height)
      (let* ((player (bongo-lyrics-live-player))
             (total (bongo-lyrics-total-time))
             (elapsed (or (bongo-lyrics-elapsed-time) 0.0))
             (index (bongo-lyrics-current-index))
             (entries (bongo-lyrics-timed-lines))
             (has-line (and entries index
                            (>= index 0)
                            (< index (length entries))))
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
                                       (/ (car (aref entries index))
                                          total)))
                           0.0))
             (empty (bongo-player--face-color 'bongo-player-progress-empty
                                              :foreground #x60))
             (track (bongo-player--face-color 'bongo-player-progress-track
                                              :foreground))
             (current (bongo-player--face-color
                       'bongo-player-progress-current :foreground))
             (background (bongo-player--face-color
                          (bongo-player--mode-line-face) :background))
             (thickness (max 2 (min 8 (/ height 4))))
             (top (max 0 (/ (- height thickness) 2)))
             (head (min (1- width) (round (* position (1- width))))))
        (fillarray data background)
        (dotimes (x width)
          (let* ((fraction (/ (float x) (max 1 (1- width))))
                 (color (cond
                         ((<= fraction position)
                          (if (and has-line (>= fraction line-start))
                              current
                            track))
                         (t empty))))
            (dotimes (dy thickness)
              (aset data (+ (* (+ top dy) width) x) color))))
        (when (and (> position 0.0) (< position 1.0))
          (let ((from (max 0 (- top 2)))
                (to (min (1- height) (+ top thickness 1))))
            (while (< from to)
              (aset data (+ (* from width) head) current)
              (setq from (1+ from)))))))))

(defun bongo-player--update-progress ()
  "Resize and repaint the mode line progress canvas when needed."
  (if (not (and bongo-player-progress-bar
                (bongo-player--buffer)
                (bongo-player--window)))
      (when bongo-player--progress-canvas
        (image-flush bongo-player--progress-canvas t)
        (setq bongo-player--progress-canvas nil
              bongo-player--progress-data nil
              bongo-player--progress-canvas-width nil
              bongo-player--progress-canvas-height nil))
    (let ((width (bongo-player--progress-width))
          (height (bongo-player--progress-height)))
      (when (or (null bongo-player--progress-canvas)
                (/= width (or bongo-player--progress-canvas-width 0))
                (/= height (or bongo-player--progress-canvas-height 0)))
        (bongo-player--create-progress-canvas width height))
      (bongo-player--paint-progress-canvas)
      (canvas-refresh bongo-player--progress-canvas 'reload-data))))


;;;; Rendering

(defun bongo-player--render-header ()
  "Redraw the body header of the player buffer.
The title and the buttons live in the header line; here we only
insert the track information and the visualizer canvas."
  (let ((inhibit-read-only t)
        (start (if (marker-position bongo-player--header-end)
                   (marker-position bongo-player--header-end)
                 (point-min))))
    (goto-char (point-min))
    (delete-region (point-min) start)
    (goto-char (point-min))
    (let ((info (string-join
                 (delq nil (list (nth 1 bongo-player--last-track)
                                 (nth 3 bongo-player--last-track)))
                 " \u2014 ")))
      (unless (string-empty-p info)
        (insert (propertize info 'face 'bongo-player-info))
        (insert "\n")))
    (when bongo-player--canvas
      (insert " ")
      (insert (propertize " " 'display bongo-player--canvas))
      (insert "\n"))
    (insert "\n")
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
    (setq bongo-player--lyrics-start (copy-marker (point-min)))
    (setq bongo-player--spacer nil
          bongo-player--spacer-height nil
          bongo-player--spacer-value nil
          bongo-player--current-line nil))
  (unless (bongo-player--window)
    (setq bongo-player--window
          (display-buffer
           bongo-player--buffer
           `(display-buffer-at-bottom
             (window-height . ,bongo-player-window-height)
             (dedicated . side))))))

(defun bongo-player--teardown-buffer ()
  "Remove the player buffer and its window."
  (when (window-live-p bongo-player--window)
    (ignore-errors (delete-window bongo-player--window)))
  (when bongo-player--progress-canvas
    (image-flush bongo-player--progress-canvas t))
  (let ((buffer (bongo-player--buffer)))
    (when buffer
      (kill-buffer buffer)))
  (setq bongo-player--buffer nil
        bongo-player--window nil
        bongo-player--header-end nil
        bongo-player--lyrics-start nil
        bongo-player--progress-canvas nil
        bongo-player--progress-data nil
        bongo-player--progress-canvas-width nil
        bongo-player--progress-canvas-height nil
        bongo-player--spacer nil
        bongo-player--spacer-height nil
        bongo-player--spacer-value nil
        bongo-player--current-line nil
        bongo-player--rendered-index nil
        bongo-player--last-track nil
        bongo-player--dirty t))

;;;###autoload
(define-minor-mode bongo-player-mode
  "Toggle the Bongo player buffer.
The buffer shows the track title and widget buttons in its header
line, the visualizer, scrolling lyrics, and a canvas progress bar
in its mode line for the track that Bongo is playing.  This is a
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
