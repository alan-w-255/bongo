;;; bongo-lyrics.el --- Synchronized lyrics display for Bongo -*- lexical-binding: t; -*-

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

;; `bongo-lyrics-mode' displays the lyrics of the track playing in
;; Bongo, following the playback position.  For synchronized (LRC)
;; lyrics the current line is highlighted and kept vertically centred
;; while the text scrolls, pixel by pixel, between lines.
;;
;; Lyrics are looked up in this order:
;;
;;   1. A `.lrc' file next to the track, or in
;;      `bongo-lyrics-lrc-directory'.
;;   2. A cached lookup, including files saved with
;;      `bongo-lyrics-load-file' in the lyrics buffer.
;;   3. Lyrics embedded in the track's tags, read with
;;      `bongo-lyrics-ffprobe-program' (usually ffprobe).
;;   4. The lrclib.net API, asynchronously, when
;;      `bongo-lyrics-fetch-online' is non-nil.  When the exact
;;      lookup misses, the search API is tried as a fallback.
;;
;; The text is rendered in an ordinary read-only buffer shown in a side
;; window: that gives wrapping, faces and CJK for free.  Scrolling uses
;; the window primitives `set-window-start' and `set-window-vscroll',
;; so no images are involved.  A text progress bar is drawn in the
;; window's header line, and an optional one-line bar of widget
;; push-buttons (see `bongo-lyrics-controls') offers offset, reload and
;; file-picking controls.
;;
;; Usage:
;;
;;   (require 'bongo-lyrics)
;;   (bongo-lyrics-mode 1)
;;
;; While the mode is on, the side window follows whichever Bongo playlist
;; buffer currently has an active player.

;;; Code:

(require 'bongo)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-util)
(require 'wid-edit)


;;;; Customization

(defgroup bongo-lyrics nil
  "Synchronized lyrics display for Bongo."
  :group 'bongo
  :prefix "bongo-lyrics-")

(defface bongo-lyrics-current-line
  '((t :inherit highlight :extend t))
  "Face for the lyric line that is currently playing."
  :group 'bongo-lyrics)

(defface bongo-lyrics-instrumental
  '((t :inherit shadow :slant italic))
  "Face for instrumental passages in the lyrics."
  :group 'bongo-lyrics)

(defface bongo-lyrics-inactive
  '((t :inherit shadow))
  "Face for status messages shown in place of lyrics."
  :group 'bongo-lyrics)

(defface bongo-lyrics-progress-empty
  '((t :inherit shadow))
  "Face for the unsung part of the header line progress bar."
  :group 'bongo-lyrics)

(defface bongo-lyrics-progress-track
  '((t :foreground "#a06aa8"))
  "Face for the elapsed part of the progress bar."
  :group 'bongo-lyrics)

(defface bongo-lyrics-progress-current
  '((t :foreground "#e26aa2" :weight bold))
  "Face for the part of the progress bar covered by the current line."
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-buffer-name "*Bongo Lyrics*"
  "Name of the buffer displaying the lyrics."
  :type 'string
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-side 'bottom
  "Side used to display the lyrics window.
One of `bottom', `top', `left' or `right'."
  :type '(choice (const bottom) (const top) (const left) (const right))
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-window-height 8
  "Height in lines of the lyrics side window when it is horizontal."
  :type 'integer
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-window-width 40
  "Width in columns of the lyrics side window when it is vertical."
  :type 'integer
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-refresh-interval 0.1
  "Seconds between playback-position updates.
A small value makes the scrolling smoother at the cost of more work."
  :type 'number
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-smooth-scroll t
  "Whether to scroll the lyrics by fractions of a line.
When nil, the window jumps from line to line instead."
  :type 'boolean
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-offset 0.0
  "User adjustment, in seconds, added to every lyric timestamp.
Positive values make lyrics appear later.  This is added on top of any
`[offset:]' tag found in an LRC file."
  :type 'number
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-lrc-directory nil
  "Directory searched for ``ARTIST - TITLE.lrc'' files.
In addition to the directory containing the track itself."
  :type '(choice (const :tag "None" nil) directory)
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-use-embedded t
  "Whether to look for lyrics embedded in the track's tags.
This uses `bongo-lyrics-ffprobe-program'."
  :type 'boolean
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-ffprobe-program "ffprobe"
  "Program used to extract embedded lyrics from a track."
  :type 'string
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-fetch-online t
  "Whether to look lyrics up online when they are not found locally.
The lyrics are downloaded from lrclib.net and cached in
`bongo-lyrics-cache-directory'."
  :type 'boolean
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-fetch-timeout 15
  "Seconds after which a pending online lookup is considered failed."
  :type 'number
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-cache-directory
  (locate-user-emacs-file "bongo-lyrics/")
  "Directory where downloaded lyrics are cached."
  :type 'directory
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-progress-bar t
  "Whether to show a progress bar in the lyrics header line.
The bar is plain text, built from block characters and faces."
  :type 'boolean
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-progress-width nil
  "Width of the progress bar in columns.
A value of nil means use the width of the lyrics window."
  :type '(choice (const :tag "Window width" nil) integer)
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-controls t
  "Whether to show a one-line widget control bar beside the lyrics.
The bar holds push-buttons for nudging the offset, reloading the
lyrics and picking a lyrics file, built with the Emacs widget
library.  Widgets only work in a real buffer, hence the separate
one-line window."
  :type 'boolean
  :group 'bongo-lyrics)

(defcustom bongo-lyrics-controls-buffer-name "*Bongo Lyrics Controls*"
  "Name of the buffer holding the lyrics control widgets."
  :type 'string
  :group 'bongo-lyrics)


;;;; State

(defvar bongo-lyrics--track-id nil
  "Identity of the track whose lyrics are currently loaded.
A list of (FILE ARTIST TITLE ALBUM DURATION), or nil when no track
is loaded.")

(defvar bongo-lyrics--title ""
  "Human-readable title of the current track.")

(defvar bongo-lyrics--entries nil
  "Vector of (TIME . TEXT) pairs for synchronized lyrics, or nil.
TIME is a float number of seconds from the start of the track.")

(defvar bongo-lyrics--plain nil
  "List of plain, unsynchronized lyric lines, or nil.")

(defvar bongo-lyrics--offset 0.0
  "Offset in seconds read from the current LRC file's [offset:] tag.")

(defvar bongo-lyrics--index nil
  "Index in `bongo-lyrics--entries' of the line currently playing.")

(defvar bongo-lyrics--origin nil
  "Internal clock used between player time reports.
A cons of (WALL-CLOCK . PLAYBACK-POSITION) in seconds.")

(defvar bongo-lyrics--paused-elapsed nil
  "Playback position frozen when the current track was paused.")

(defvar bongo-lyrics--ignore-cache nil
  "When non-nil, do not read the lyrics cache.")

(defvar bongo-lyrics--fetching nil
  "Key of the track whose online lookup is in flight, or nil.")

(defvar bongo-lyrics--fetch-timer nil
  "Timer that gives up on the pending online lookup.")

(defvar bongo-lyrics--window nil
  "Window displaying the lyrics buffer.")

(defvar bongo-lyrics--overlay nil
  "Overlay marking the current lyric line.")

(defvar bongo-lyrics--timer nil
  "Timer driving the lyrics display.")

(defvar bongo-lyrics--controls-window nil
  "Window displaying the widget control bar.")

(defvar bongo-lyrics--line-cache nil
  "Cons of (INDEX . PIXEL-HEIGHT) caching a measured lyric line.")

(defvar bongo-lyrics-mode)
(defvar bongo-player)


;;;; LRC parsing

(defconst bongo-lyrics--timestamp-re
  "\\`\\([0-9]+\\):\\([0-9]+\\)\\(?:[.:]\\([0-9]+\\)\\)?\\'"
  "Regexp matching the inside of an LRC timestamp tag.")

(defconst bongo-lyrics--metadata-re
  "\\`\\(?:ar\\|al\\|au\\|by\\|ktv\\|length\\|lr\\|re\\|ti\\|ve\\):"
  "Regexp matching the inside of an LRC metadata tag other than offset.")

(defun bongo-lyrics--timestamp-seconds (tag)
  "Return the number of seconds encoded in the LRC timestamp TAG."
  (string-match bongo-lyrics--timestamp-re tag)
  (+ (* 60 (string-to-number (match-string 1 tag)))
     (string-to-number (match-string 2 tag))
     (let ((fraction (match-string 3 tag)))
       (if fraction
           (/ (string-to-number fraction) (expt 10.0 (length fraction)))
         0.0))))

(defun bongo-lyrics--parse-lrc (string)
  "Parse STRING as LRC-encoded lyrics.
Return a plist with the following keys:

  :offset  The value of an [offset:] tag, in seconds (default 0.0).
  :lines   A vector of (TIME . TEXT) pairs sorted by TIME, or nil
           when STRING contains no timestamps.
  :plain   A list of lines when STRING contains no timestamps."
  (let ((offset 0.0)
        (entries nil)
        (plain nil)
        (timed nil))
    (dolist (raw (split-string string "\r?\n"))
      (let* ((line (string-trim-left raw))
             (length (length line))
             (pos 0)
             (times nil)
             (continue t))
        ;; Consume the leading [..] tags of the line.  The first tag
        ;; that is not recognized ends the tag run, so that plain text
        ;; such as "[Chorus]" is preserved.
        (while (and continue (< pos length) (eq (aref line pos) ?\[))
          (let ((end (cl-position ?\] line :start (1+ pos))))
            (if (null end)
                (setq continue nil)
              (let ((tag (substring line (1+ pos) end)))
                (cond
                 ((string-match bongo-lyrics--timestamp-re tag)
                  (setq timed t)
                  (push (bongo-lyrics--timestamp-seconds tag) times)
                  (setq pos (1+ end)))
                 ((string-match bongo-lyrics--metadata-re tag)
                  (setq pos (1+ end)))
                 ((string-match "\\`offset:\\([-+]?[0-9]+\\)\\'" tag)
                  (setq offset (/ (string-to-number (match-string 1 tag))
                                  1000.0))
                  (setq pos (1+ end)))
                 (t
                  (setq continue nil)))))))
        (let ((text (string-trim (substring line (min pos length)))))
          (cond
           (times
            (dolist (time times)
              (push (cons time text) entries)))
           ((not (string-empty-p text))
            (push text plain))))))
    (list :offset offset
          :lines (and timed entries
                      (vconcat (sort entries
                                     (lambda (a b) (< (car a) (car b))))))
          :plain (and (not timed) (nreverse plain)))))


;;;; Lyric sources

(defun bongo-lyrics--file-contents (file)
  "Return the contents of FILE, or nil if it is empty or unreadable."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (unless (string-empty-p (string-trim text))
          text)))))

(defun bongo-lyrics--sidecar-file (file artist title)
  "Return an existing lyric file for FILE, ARTIST and TITLE, or nil.
Candidates are ``BASENAME.lrc'' and ``ARTIST - TITLE.lrc'' next to
the track and in `bongo-lyrics-lrc-directory'."
  (let* ((dir (file-name-directory file))
         (base (file-name-base file))
         (names (delq nil
                      (list base
                            (and artist title (concat artist " - " title))
                            title)))
         (directories (delq nil (list dir bongo-lyrics-lrc-directory)))
         (candidates
          (cl-loop for name in names
                   append (cl-loop for directory in directories
                                   append (mapcar
                                           (lambda (extension)
                                             (expand-file-name
                                              (concat name extension)
                                              directory))
                                           '(".lrc" ".LRC" ".Lyrics"))))))
    (cl-find-if #'file-readable-p (delete-dups candidates))))

(defun bongo-lyrics--embedded-lyrics (file)
  "Return lyrics embedded in FILE's tags, or nil.
The tags are read with `bongo-lyrics-ffprobe-program'."
  (when (and bongo-lyrics-use-embedded
             (stringp file)
             (file-readable-p file)
             (not (bongo-uri-p file))
             (executable-find bongo-lyrics-ffprobe-program))
    (with-temp-buffer
      (let ((status (ignore-errors
                      (call-process bongo-lyrics-ffprobe-program
                                    nil t nil
                                    "-v" "error"
                                    "-show_entries" "format_tags"
                                    "-of" "json"
                                    file))))
        (when (and (integerp status) (zerop status))
          (goto-char (point-min))
          (let* ((json (ignore-errors
                         (json-parse-buffer :object-type 'alist
                                            :null-object nil)))
                 (tags (alist-get 'tags (alist-get 'format json))))
            (cl-loop for (key . value) in tags
                     when (and (stringp value)
                               (not (string-empty-p value))
                               (string-match-p "lyric" (symbol-name key)))
                     return value)))))))

(defun bongo-lyrics--cache-file (key)
  "Return the cache file name for the track described by KEY.
Tagged tracks are cached by artist, title and album; untagged ones
by their file name, so that different files cannot share a slot."
  (let* ((file (nth 0 key))
         (artist (nth 1 key))
         (title (nth 2 key))
         (album (nth 3 key))
         (identity (cond
                    ((and artist title)
                     (format "%s\0%s\0%s" artist title (or album "")))
                    ((stringp file)
                     (expand-file-name file))
                    (t
                     (format "%s" (or title ""))))))
    (expand-file-name
     (concat (md5 identity) ".lrc")
     bongo-lyrics-cache-directory)))

(defun bongo-lyrics--cache-read (key)
  "Return cached lyrics for the track described by KEY, or nil."
  (bongo-lyrics--file-contents (bongo-lyrics--cache-file key)))

(defun bongo-lyrics--cache-write (key text)
  "Store TEXT as the cached lyrics for the track described by KEY."
  (ignore-errors
    (make-directory bongo-lyrics-cache-directory t)
    (with-temp-file (bongo-lyrics--cache-file key)
      (insert text))))

(defun bongo-lyrics--cancel-fetch ()
  "Forget any pending online lookup."
  (when bongo-lyrics--fetch-timer
    (cancel-timer bongo-lyrics--fetch-timer)
    (setq bongo-lyrics--fetch-timer nil))
  (setq bongo-lyrics--fetching nil))

(defun bongo-lyrics--finish-fetch (key text)
  "Install TEXT as the lyrics of the track described by KEY.
When TEXT is nil, show that no lyrics could be found."
  (when (equal key bongo-lyrics--fetching)
    (bongo-lyrics--cancel-fetch)
    (when (and bongo-lyrics-mode (equal key bongo-lyrics--track-id))
      (if (and (stringp text) (not (string-empty-p text)))
          (progn
            (bongo-lyrics--cache-write key text)
            (bongo-lyrics--apply-text text))
        (bongo-lyrics--render-pending "No lyrics found")))))

(defun bongo-lyrics--fetch-timed-out (key)
  "Give up on the pending online lookup for KEY."
  (when (equal key bongo-lyrics--fetching)
    (bongo-lyrics--finish-fetch key nil)))

(defun bongo-lyrics--lrclib-url (key kind)
  "Return the lrclib.net URL for the track described by KEY.
KIND is `get' for the exact lookup or `search' for the fallback."
  (let ((artist (nth 1 key))
        (title (nth 2 key))
        (album (nth 3 key))
        (duration (nth 4 key)))
    (if (eq kind 'get)
        (concat "https://lrclib.net/api/get?"
                (url-build-query-string
                 (delq nil
                       (list (and artist (list "artist_name" artist))
                             (and title (list "track_name" title))
                             (and album (list "album_name" album))
                             (and duration
                                  (list "duration"
                                        (number-to-string
                                         (round duration))))))))
      (concat "https://lrclib.net/api/search?"
              (url-build-query-string
               (list (list "q"
                           (string-join (delq nil (list artist title)) " "))))))))

(defun bongo-lyrics--request (url key kind)
  "Start an asynchronous lrclib.net request for URL, KEY and KIND."
  (let ((url-request-extra-headers
         '(("User-Agent" . "bongo-lyrics.el/0.1 (Emacs)"))))
    (url-retrieve url #'bongo-lyrics--lrclib-callback (list key kind) t)))

(defun bongo-lyrics--fetch-online (key)
  "Look the track described by KEY up on lrclib.net, asynchronously.
Return non-nil if a request was actually started.  KEY is a list of
  (FILE ARTIST TITLE ALBUM DURATION)."
  (when (or (nth 1 key) (nth 2 key))
    (bongo-lyrics--cancel-fetch)
    (setq bongo-lyrics--fetching key
          bongo-lyrics--fetch-timer
          (run-with-timer bongo-lyrics-fetch-timeout nil
                          #'bongo-lyrics--fetch-timed-out key))
    (condition-case err
        (let ((kind (if (and (nth 1 key) (nth 2 key)) 'get 'search)))
          (bongo-lyrics--request (bongo-lyrics--lrclib-url key kind) key kind)
          t)
      (error
       (bongo-lyrics--cancel-fetch)
       (message "bongo-lyrics: %s" (error-message-string err))
       nil))))

(defun bongo-lyrics--best-result (results key)
  "Return the best lyric text among lrclib.net search RESULTS for KEY.
Synchronized lyrics are preferred, then results whose duration is
closest to the duration in KEY."
  (let ((duration (nth 4 key))
        (best nil)
        (best-score nil))
    (mapc
     (lambda (result)
       (let* ((synced (alist-get 'syncedLyrics result))
              (plain (alist-get 'plainLyrics result))
              (has-synced (and (stringp synced)
                               (not (string-empty-p synced))))
              (text (if has-synced synced plain))
              (result-duration (alist-get 'duration result))
              (difference (if (and (numberp duration)
                                   (numberp result-duration))
                              (abs (- duration result-duration))
                            1e9))
              (score (list (if has-synced 0 1) difference)))
         (when (and (stringp text) (not (string-empty-p text))
                    (or (null best-score)
                        (< (car score) (car best-score))
                        (and (= (car score) (car best-score))
                             (< (cadr score) (cadr best-score)))))
           (setq best text
                 best-score score))))
     results)
    best))

(defun bongo-lyrics--lrclib-callback (status key kind)
  "Handle the lrclib.net response described by STATUS for KEY and KIND."
  (let ((buffer (current-buffer))
        (json nil))
    (unwind-protect
        (when (and (not (plist-get status :error))
                   (progn (goto-char (point-min))
                          (re-search-forward "^$" nil t)))
          (setq json (ignore-errors
                       (json-parse-buffer :object-type 'alist
                                          :null-object nil))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (when (equal key bongo-lyrics--fetching)
      (pcase kind
        ('get
         (let ((text (and json (or (alist-get 'syncedLyrics json)
                                   (alist-get 'plainLyrics json)))))
           (if (and (stringp text) (not (string-empty-p text)))
               (bongo-lyrics--finish-fetch key text)
             ;; The exact lookup missed: try the fuzzy search instead.
             (condition-case nil
                 (bongo-lyrics--request
                  (bongo-lyrics--lrclib-url key 'search) key 'search)
               (error
                (bongo-lyrics--finish-fetch key nil))))))
        (_
         (bongo-lyrics--finish-fetch
          key (and (sequencep json) (bongo-lyrics--best-result json key))))))))


;;;; The player and its clock

(defun bongo-lyrics--player ()
  "Return the active Bongo player, or nil.  Does not create buffers."
  (catch 'found
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and (bongo-playlist-buffer-p)
                     bongo-player
                     (bongo-player-running-p bongo-player))
            (throw 'found bongo-player)))))
    nil))

(defun bongo-lyrics--track-key (player)
  "Return an identity for the track PLAYER is playing.
The identity is a list of (FILE ARTIST TITLE ALBUM DURATION), any of
whose elements may be nil."
  (let ((infoset (ignore-errors (bongo-player-infoset player))))
    (list (ignore-errors (bongo-player-file-name player))
          (ignore-errors (bongo-infoset-artist-name infoset))
          (ignore-errors (bongo-infoset-track-title infoset))
          (ignore-errors (bongo-infoset-album-title infoset))
          (ignore-errors (bongo-player-total-time player)))))

(defun bongo-lyrics--derived-elapsed ()
  "Return the playback position derived from the internal clock."
  (when bongo-lyrics--origin
    (+ (cdr bongo-lyrics--origin)
       (- (float-time) (car bongo-lyrics--origin)))))

(defun bongo-lyrics--elapsed (player)
  "Return PLAYER's interpolated playback position in seconds.
Unlike `bongo-player-elapsed-time', the value is updated continuously
between the backend's own reports."
  (cond
   ((null player)
    (or bongo-lyrics--paused-elapsed 0.0))
   ((bongo-player-paused-p player)
    (or (bongo-player-elapsed-time player)
        bongo-lyrics--paused-elapsed
        (bongo-lyrics--derived-elapsed)
        0.0))
   (t
    (or (bongo-lyrics--derived-elapsed)
        (bongo-player-elapsed-time player)
        0.0))))

(defun bongo-lyrics--sync-clock (player)
  "Keep the internal clock in step with PLAYER.
The player backends report the position at most a few times per
second, so a wall-clock offset is used in between and gently
corrected when the reports disagree with it."
  (let ((reported (bongo-player-elapsed-time player))
        (now (float-time)))
    (if (bongo-player-paused-p player)
        (progn
          (when (null bongo-lyrics--paused-elapsed)
            (setq bongo-lyrics--paused-elapsed
                  (or reported
                      (bongo-lyrics--derived-elapsed)
                      0.0)))
          (setq bongo-lyrics--origin nil))
      (cond
       ((null bongo-lyrics--origin)
        (setq bongo-lyrics--origin
              (cons now (or reported bongo-lyrics--paused-elapsed 0.0)))
        (setq bongo-lyrics--paused-elapsed nil))
       ((and reported
             (> (abs (- reported
                        (+ (cdr bongo-lyrics--origin)
                           (- now (car bongo-lyrics--origin)))))
                0.75))
        (setq bongo-lyrics--origin (cons now reported)))))))


;;;; Display

(defvar bongo-lyrics-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'bongo-lyrics-seek-to-line)
    (define-key map [mouse-1] #'bongo-lyrics-seek-to-line)
    (define-key map (kbd "g") #'bongo-lyrics-reload)
    (define-key map (kbd "f") #'bongo-lyrics-load-file)
    (define-key map (kbd "F") #'bongo-lyrics-forget)
    (define-key map (kbd "+") #'bongo-lyrics-offset-later)
    (define-key map (kbd "-") #'bongo-lyrics-offset-earlier)
    (define-key map (kbd "0") #'bongo-lyrics-reset-offset)
    map)
  "Keymap used in the lyrics buffer.")

(define-derived-mode bongo-lyrics-view-mode special-mode "Bongo-Lyrics"
  "Major mode displaying synchronized lyrics.

\\{bongo-lyrics-view-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format '(:eval (bongo-lyrics--mode-line)))
  (setq-local header-line-format '(:eval (bongo-lyrics--header-line))))

(defun bongo-lyrics--window ()
  "Return the live window displaying the lyrics buffer, or nil."
  (and (window-live-p bongo-lyrics--window)
       (eq (window-buffer bongo-lyrics--window)
           (get-buffer bongo-lyrics-buffer-name))
       bongo-lyrics--window))

(defun bongo-lyrics--lyrics-buffer ()
  "Return the live lyrics buffer, or nil."
  (let ((buffer (get-buffer bongo-lyrics-buffer-name)))
    (and (buffer-live-p buffer) buffer)))

(defun bongo-lyrics--line-position (index)
  "Return the buffer position at the start of lyric line INDEX."
  (let ((buffer (bongo-lyrics--lyrics-buffer)))
    (when buffer
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (forward-line index)
          (unless (eobp) (point)))))))

(defun bongo-lyrics--mode-line ()
  "Return the mode line construct for the lyrics buffer."
  (concat " " (if (string-empty-p bongo-lyrics--title)
                  "Bongo Lyrics"
                bongo-lyrics--title)
          (when (/= bongo-lyrics-offset 0.0)
            (format " [%+g s]" bongo-lyrics-offset))))

(defun bongo-lyrics--header-line ()
  "Return the header line construct with the progress bar."
  (when bongo-lyrics-progress-bar
    (bongo-lyrics--progress-string)))


;;;; Rendering the text

(defun bongo-lyrics--render-buffer ()
  "Fill the lyrics buffer from the current lyric variables."
  (let ((buffer (get-buffer-create bongo-lyrics-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'bongo-lyrics-view-mode)
        (bongo-lyrics-view-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         (bongo-lyrics--entries
          (cl-loop for entry across bongo-lyrics--entries
                   for text = (cdr entry)
                   do (insert (if (string-empty-p (string-trim text))
                                  (propertize "\u266a"
                                              'face 'bongo-lyrics-instrumental)
                                text))
                      (insert "\n")))
         (bongo-lyrics--plain
          (insert (mapconcat #'identity bongo-lyrics--plain "\n"))
          (insert "\n"))
         (t
          (insert (propertize "No lyrics available."
                              'face 'bongo-lyrics-inactive)
                  "\n"))))
      (when (overlayp bongo-lyrics--overlay)
        (delete-overlay bongo-lyrics--overlay))
      (setq bongo-lyrics--overlay nil)
      (setq-local header-line-format '(:eval (bongo-lyrics--header-line)))
      (setq-local mode-line-format '(:eval (bongo-lyrics--mode-line))))
    (setq bongo-lyrics--line-cache nil)))

(defun bongo-lyrics--render-pending (message)
  "Show MESSAGE in the lyrics buffer in place of lyrics."
  (setq bongo-lyrics--entries nil
        bongo-lyrics--plain nil
        bongo-lyrics--index nil)
  (let ((buffer (bongo-lyrics--lyrics-buffer)))
    (when buffer
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize message 'face 'bongo-lyrics-inactive) "\n"))))))

(defun bongo-lyrics--highlight (index)
  "Highlight lyric line INDEX."
  (let ((buffer (bongo-lyrics--lyrics-buffer)))
    (when buffer
      (with-current-buffer buffer
        (when (overlayp bongo-lyrics--overlay)
          (delete-overlay bongo-lyrics--overlay))
        (setq bongo-lyrics--overlay nil)
        (when index
          (save-excursion
            (goto-char (point-min))
            (forward-line index)
            (let ((overlay (make-overlay (point) (line-end-position))))
              (overlay-put overlay 'face 'bongo-lyrics-current-line)
              (setq bongo-lyrics--overlay overlay))))))))

(defun bongo-lyrics--line-pixel-height (window position)
  "Return the pixel height of the line at POSITION in WINDOW.
The window's vscroll is reset first, because a partially scrolled
line would otherwise be measured as shorter than it really is."
  (let ((buffer (bongo-lyrics--lyrics-buffer)))
    (when buffer
      (with-current-buffer buffer
        (let ((end (save-excursion
                     (goto-char position)
                     (min (point-max) (1+ (line-end-position))))))
          (set-window-vscroll window 0 t)
          (cdr (ignore-errors
                 (window-text-pixel-size window position end))))))))

(defun bongo-lyrics--scroll (index elapsed)
  "Scroll the lyrics window so that line INDEX is centred.
ELAPSED is the current playback position, used to interpolate the
scroll position between line INDEX and the next one."
  (let ((window (bongo-lyrics--window)))
    (when (and window index)
      (let* ((frame (window-frame window))
             (char-height (max 1 (frame-char-height frame)))
             (body (or (ignore-errors (window-body-height window t))
                       (* char-height (window-body-height window))))
             (visible (max 1 (/ body char-height)))
             (half (max 0 (1- (/ visible 2))))
             (start-index (max 0 (- index half)))
             (position (bongo-lyrics--line-position start-index)))
        (when position
          (let ((vscroll
                 (if (and bongo-lyrics-smooth-scroll
                          ;; Before the current line reaches the middle
                          ;; of the window the text cannot scroll up any
                          ;; further, so leave it at the top.
                          (>= index half))
                     (let ((height
                            (if (and (consp bongo-lyrics--line-cache)
                                     (eql (car bongo-lyrics--line-cache)
                                          start-index))
                                (cdr bongo-lyrics--line-cache)
                              (let ((measured
                                     (or (bongo-lyrics--line-pixel-height
                                          window position)
                                         char-height)))
                                (setq bongo-lyrics--line-cache
                                      (cons start-index measured))
                                measured))))
                       (min (1- (max 1 height))
                            (round (* (bongo-lyrics--fraction index elapsed)
                                      height))))
                   0)))
            ;; Redisplay insists on keeping the window's own point fully
            ;; visible.  When the first line is partly scrolled out, point
            ;; must not sit on it, or the window would be scrolled back.
            (let* ((first-visible (if (> vscroll 0)
                                      (or (bongo-lyrics--line-position
                                           (1+ start-index))
                                          position)
                                    position))
                   (after-visible
                    (bongo-lyrics--line-position (+ start-index visible)))
                   (point (window-point window)))
              (when (or (< point first-visible)
                        (and after-visible (>= point after-visible)))
                (set-window-point
                 window
                 (if (and (> vscroll 0) (= index start-index))
                     first-visible
                   (or (bongo-lyrics--line-position index) position)))))
            (set-window-start window position)
            ;; PRESERVE-VSCROLL-P is needed because forcing the start
            ;; above makes redisplay clear the vscroll otherwise.
            (set-window-vscroll window vscroll t t)))))))

(defun bongo-lyrics--index-at (elapsed)
  "Return the index of the last lyric line starting at or before ELAPSED."
  (let* ((entries bongo-lyrics--entries)
         (length (length entries))
         (low 0)
         (high (1- length))
         (found nil))
    (while (<= low high)
      (let ((middle (/ (+ low high) 2)))
        (if (<= (car (aref entries middle)) elapsed)
            (setq found middle
                  low (1+ middle))
          (setq high (1- middle)))))
    found))

(defun bongo-lyrics--fraction (index elapsed)
  "Return how far ELAPSED is between line INDEX and the next line."
  (if (or (null index) (null bongo-lyrics--entries)
          (>= (1+ index) (length bongo-lyrics--entries)))
      0.0
    (let* ((entries bongo-lyrics--entries)
           (start (car (aref entries index)))
           (end (car (aref entries (1+ index)))))
      (if (<= end start)
          0.0
        (max 0.0 (min 1.0 (/ (- elapsed start) (- end start))))))))

(defun bongo-lyrics--update-position (elapsed &optional force)
  "Update the highlighted line and scroll position for ELAPSED.
When FORCE is non-nil, re-highlight the current line even if it has
not changed."
  (when bongo-lyrics--entries
    (let ((index (bongo-lyrics--index-at elapsed)))
      (when (or force (not (eql index bongo-lyrics--index)))
        (setq bongo-lyrics--index index)
        (bongo-lyrics--highlight index))
      (bongo-lyrics--scroll index elapsed))))


;;;; The progress bar

(defconst bongo-lyrics--progress-blocks
  ["\u258f" "\u258e" "\u258d" "\u258c" "\u258b" "\u258a" "\u2589" "\u2588"]
  "Fractional block characters used to draw the progress bar.")

(defun bongo-lyrics--progress-columns ()
  "Return the width in columns of the progress bar."
  (or bongo-lyrics-progress-width
      (let ((window (bongo-lyrics--window)))
        (and window
             (let ((width (window-body-width window)))
               (and (> width 1) (1- width)))))
      30))

(defun bongo-lyrics--progress-string ()
  "Return the header line progress bar as a propertized string.
The bar shows the position in the whole track.  The part covered by
the line currently being sung is drawn in a brighter face."
  (let* ((width (bongo-lyrics--progress-columns))
         (player (ignore-errors (bongo-lyrics--player)))
         (total (and player
                     (ignore-errors (bongo-player-total-time player))))
         (elapsed (+ (bongo-lyrics--elapsed player)
                     bongo-lyrics--offset
                     bongo-lyrics-offset))
         (has-line (and bongo-lyrics--entries bongo-lyrics--index))
         (position
          (cond
           ((null player) 0.0)
           ((and total (> total 0.0))
            (max 0.0 (min 1.0 (/ elapsed total))))
           ((and bongo-lyrics--index bongo-lyrics--entries)
            (bongo-lyrics--fraction bongo-lyrics--index elapsed))
           (t 0.0)))
         (line-start
          (if (and has-line total (> total 0.0))
              (max 0.0
                   (min 1.0
                        (/ (car (aref bongo-lyrics--entries
                                      bongo-lyrics--index))
                           total)))
            0.0))
         (cells nil))
    (dotimes (i width)
      (let* ((low (/ (float i) width))
             (high (/ (float (1+ i)) width))
             (middle (/ (+ low high) 2.0))
             (fill (max 0.0 (min 1.0 (/ (- position low) (- high low)))))
             (face (cond
                    ((<= fill 0.0) 'bongo-lyrics-progress-empty)
                    ((and has-line (>= middle line-start))
                     'bongo-lyrics-progress-current)
                    (t 'bongo-lyrics-progress-track))))
        (push (propertize
               (cond
                ((<= fill 0.0) "\u2591")
                ((>= fill 1.0) "\u2588")
                (t (aref bongo-lyrics--progress-blocks
                         (1- (max 1 (min 8 (ceiling (* fill 8))))))))
               'face face)
              cells)))
    (apply #'concat (nreverse cells))))

(defun bongo-lyrics--update-header-line ()
  "Mark the lyrics header line for redisplay."
  (let ((buffer (bongo-lyrics--lyrics-buffer)))
    (when buffer
      (with-current-buffer buffer
        (force-mode-line-update)))))


;;;; Loading lyrics for a track

(defun bongo-lyrics--apply-text (text)
  "Parse TEXT and display it, then position the display."
  (let* ((parsed (bongo-lyrics--parse-lrc text))
         (entries (plist-get parsed :lines)))
    (setq bongo-lyrics--offset (or (plist-get parsed :offset) 0.0)
          bongo-lyrics--entries entries
          bongo-lyrics--plain (plist-get parsed :plain)
          bongo-lyrics--index nil)
    (bongo-lyrics--render-buffer)
    (when entries
      (bongo-lyrics--update-position
       (+ (bongo-lyrics--elapsed (ignore-errors (bongo-lyrics--player)))
          bongo-lyrics--offset
          bongo-lyrics-offset)
       t))))

(defun bongo-lyrics--load-track (key)
  "Load lyrics for the track described by KEY."
  (let* ((file (nth 0 key))
         (artist (nth 1 key))
         (title (nth 2 key))
         (text nil))
    (setq bongo-lyrics--title
          (or (and artist title (format "%s \u2014 %s" artist title))
              title
              (and (stringp file) (file-name-base file))
              "Bongo Lyrics")
          bongo-lyrics--entries nil
          bongo-lyrics--plain nil
          bongo-lyrics--index nil
          bongo-lyrics--offset 0.0
          bongo-lyrics--line-cache nil)
    (cond
     ((and (stringp file)
           (setq text
                 (bongo-lyrics--file-contents
                  (bongo-lyrics--sidecar-file file artist title)))))
     ((and (not bongo-lyrics--ignore-cache)
           (setq text (bongo-lyrics--cache-read key))))
     ((and (stringp file)
           (setq text (bongo-lyrics--embedded-lyrics file)))
      (bongo-lyrics--cache-write key text))
     ((and bongo-lyrics-fetch-online (bongo-lyrics--fetch-online key))
      (bongo-lyrics--render-pending "Searching for lyrics\u2026"))
     (t
      (bongo-lyrics--render-pending "No lyrics found")))
    (when text
      (bongo-lyrics--cancel-fetch)
      (bongo-lyrics--apply-text text))))

(defun bongo-lyrics--update-track ()
  "Notice track changes and load the matching lyrics."
  (let ((player (ignore-errors (bongo-lyrics--player))))
    (if (null player)
        (when bongo-lyrics--track-id
          (bongo-lyrics--cancel-fetch)
          (setq bongo-lyrics--track-id nil)
          (unless (or bongo-lyrics--entries bongo-lyrics--plain)
            (setq bongo-lyrics--title "")
            (bongo-lyrics--render-pending "No track playing")))
      (let ((key (bongo-lyrics--track-key player)))
        (unless (equal key bongo-lyrics--track-id)
          (bongo-lyrics--cancel-fetch)
          (setq bongo-lyrics--track-id key
                bongo-lyrics--origin
                (cons (float-time)
                      (or (ignore-errors
                            (bongo-player-elapsed-time player))
                          0.0))
                bongo-lyrics--paused-elapsed nil)
          (bongo-lyrics--load-track key))))))

(defun bongo-lyrics--tick ()
  "Advance the lyrics display by one tick."
  (when bongo-lyrics-mode
    (let ((player (ignore-errors (bongo-lyrics--player))))
      (bongo-lyrics--update-track)
      (when player
        (bongo-lyrics--sync-clock player))
      (let ((elapsed (+ (bongo-lyrics--elapsed player)
                        bongo-lyrics--offset
                        bongo-lyrics-offset)))
        (when bongo-lyrics--entries
          (bongo-lyrics--update-position elapsed))
        (when bongo-lyrics-progress-bar
          (bongo-lyrics--update-header-line))))))


;;;; Hooks

(defun bongo-lyrics--on-started (&rest _)
  "Reset the clock when a new track starts."
  (when bongo-lyrics-mode
    (setq bongo-lyrics--origin nil
          bongo-lyrics--paused-elapsed nil)
    (bongo-lyrics--update-track)))

(defun bongo-lyrics--on-sought (&rest _)
  "Reset the clock after a seek."
  (when bongo-lyrics-mode
    (setq bongo-lyrics--origin
          (cons (float-time)
                (or (ignore-errors
                      (bongo-player-elapsed-time (bongo-lyrics--player)))
                    0.0))
          bongo-lyrics--paused-elapsed nil)))

(defun bongo-lyrics--on-paused/resumed (&rest _)
  "Reset the clock when the current track is paused or resumed."
  (when bongo-lyrics-mode
    (setq bongo-lyrics--origin nil
          bongo-lyrics--paused-elapsed nil)))

(defun bongo-lyrics--on-stopped (&rest _)
  "Freeze the display when the player stops."
  (when bongo-lyrics-mode
    (setq bongo-lyrics--paused-elapsed (bongo-lyrics--derived-elapsed)
          bongo-lyrics--origin nil)))


;;;; Commands

(defun bongo-lyrics-reload (&optional no-cache)
  "Reload the lyrics of the current track.
With prefix argument NO-CACHE, ignore the on-disk cache, forcing a
fresh online lookup."
  (interactive "P")
  (unless bongo-lyrics-mode
    (user-error "Bongo-lyrics mode is not enabled"))
  (setq bongo-lyrics--ignore-cache (and no-cache t))
  (unwind-protect
      (progn
        (setq bongo-lyrics--track-id nil)
        (bongo-lyrics--update-track))
    (setq bongo-lyrics--ignore-cache nil)))

;;;###autoload
(defun bongo-lyrics-load-file (file &optional no-cache)
  "Display lyrics from FILE for the current track.
FILE may be an LRC file or plain text.  Unless NO-CACHE is non-nil,
the file is also copied into `bongo-lyrics-cache-directory' so that
it is used automatically the next time the track is played.
Interactively, a prefix argument means do not remember it."
  (interactive "fLyrics file: \nP")
  (unless bongo-lyrics-mode
    (user-error "Bongo-lyrics mode is not enabled"))
  (let ((text (bongo-lyrics--file-contents file)))
    (unless text
      (user-error "Cannot read lyrics from %s" file))
    (bongo-lyrics--cancel-fetch)
    (when (and (not no-cache) bongo-lyrics--track-id)
      (bongo-lyrics--cache-write bongo-lyrics--track-id text))
    (bongo-lyrics--apply-text text)
    (message "Lyrics loaded from %s%s" file
             (if (and (not no-cache) bongo-lyrics--track-id)
                 " (remembered)"
               ""))))

(defun bongo-lyrics-forget ()
  "Delete the cached lyrics of the current track and look again."
  (interactive)
  (unless bongo-lyrics-mode
    (user-error "Bongo-lyrics mode is not enabled"))
  (let ((key bongo-lyrics--track-id))
    (unless key
      (user-error "No track is loaded"))
    (ignore-errors (delete-file (bongo-lyrics--cache-file key)))
    (setq bongo-lyrics--track-id nil)
    (bongo-lyrics--update-track)
    (message "Cached lyrics forgotten")))

(defun bongo-lyrics-seek-to-line (&optional position)
  "Seek playback to the lyric line at POSITION.
POSITION defaults to point."
  (interactive "d")
  (let* ((index (1- (line-number-at-pos position)))
         (entries bongo-lyrics--entries))
    (if (or (null entries) (< index 0) (>= index (length entries)))
        (message "No lyric line here")
      (let ((time (+ (car (aref entries index))
                     bongo-lyrics--offset
                     bongo-lyrics-offset)))
        (condition-case err
            (progn
              (bongo-seek-to time)
              (setq bongo-lyrics--origin (cons (float-time) time)
                    bongo-lyrics--paused-elapsed nil)
              (message "Seek to %s" (format-seconds "%m:%02s" time)))
          (error (message "%s" (error-message-string err))))))))

(defun bongo-lyrics--nudge-offset (delta)
  "Adjust `bongo-lyrics-offset' by DELTA seconds."
  (setq bongo-lyrics-offset (+ bongo-lyrics-offset delta))
  (message "Lyrics offset: %+g s" bongo-lyrics-offset)
  (when (bongo-lyrics--window)
    (with-current-buffer (bongo-lyrics--lyrics-buffer)
      (force-mode-line-update))))

(defun bongo-lyrics-offset-later (&optional n)
  "Delay lyrics by 0.5 seconds times prefix argument N."
  (interactive "p")
  (bongo-lyrics--nudge-offset (* 0.5 (or n 1))))

(defun bongo-lyrics-offset-earlier (&optional n)
  "Advance lyrics by 0.5 seconds times prefix argument N."
  (interactive "p")
  (bongo-lyrics--nudge-offset (* -0.5 (or n 1))))

(defun bongo-lyrics-reset-offset ()
  "Reset the user lyrics offset to zero."
  (interactive)
  (setq bongo-lyrics-offset 0.0)
  (message "Lyrics offset reset")
  (when (bongo-lyrics--window)
    (with-current-buffer (bongo-lyrics--lyrics-buffer)
      (force-mode-line-update))))


;;;; The widget control bar

(defun bongo-lyrics--setup-controls ()
  "Create and display the widget control bar.
Does nothing when `bongo-lyrics-controls' is nil or when widgets are
unavailable."
  (when (and bongo-lyrics-controls (fboundp 'widget-create))
    (let ((buffer (get-buffer-create bongo-lyrics-controls-buffer-name)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (setq-local cursor-type nil)
          (setq-local mode-line-format nil)
          (setq-local header-line-format nil)
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
                                   (call-interactively
                                    #'bongo-lyrics-load-file))
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
          (widget-setup)
          (goto-char (point-min))
          (setq buffer-read-only t)))
      (unless (and (window-live-p bongo-lyrics--controls-window)
                   (eq (window-buffer bongo-lyrics--controls-window)
                       buffer))
        (setq bongo-lyrics--controls-window
              (display-buffer
               buffer
               `(display-buffer-in-side-window
                 (side . ,bongo-lyrics-side)
                 (slot . 1)
                 (window-height . 1))))))))

(defun bongo-lyrics--teardown-controls ()
  "Remove the widget control bar."
  (when (window-live-p bongo-lyrics--controls-window)
    (ignore-errors (delete-window bongo-lyrics--controls-window)))
  (let ((buffer (get-buffer bongo-lyrics-controls-buffer-name)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (setq bongo-lyrics--controls-window nil))


;;;; The global minor mode

(defun bongo-lyrics--setup-buffer ()
  "Create and display the lyrics buffer."
  (let ((buffer (get-buffer-create bongo-lyrics-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'bongo-lyrics-view-mode)
        (bongo-lyrics-view-mode))
      (setq-local header-line-format '(:eval (bongo-lyrics--header-line)))
      (setq-local mode-line-format '(:eval (bongo-lyrics--mode-line))))
    (unless (bongo-lyrics--window)
      (setq bongo-lyrics--window
            (display-buffer
             buffer
             (if (memq bongo-lyrics-side '(left right))
                 `(display-buffer-in-side-window
                   (side . ,bongo-lyrics-side)
                   (slot . 0)
                   (window-width . ,bongo-lyrics-window-width))
               `(display-buffer-in-side-window
                 (side . ,bongo-lyrics-side)
                 (slot . 0)
                 (window-height . ,bongo-lyrics-window-height))))))))

(defun bongo-lyrics--teardown ()
  "Remove everything the mode set up."
  (when bongo-lyrics--timer
    (cancel-timer bongo-lyrics--timer)
    (setq bongo-lyrics--timer nil))
  (bongo-lyrics--cancel-fetch)
  (bongo-lyrics--teardown-controls)
  (when (window-live-p bongo-lyrics--window)
    (ignore-errors (delete-window bongo-lyrics--window)))
  (remove-hook 'bongo-player-started-hook #'bongo-lyrics--on-started)
  (remove-hook 'bongo-player-stopped-hook #'bongo-lyrics--on-stopped)
  (remove-hook 'bongo-player-paused/resumed-hook
               #'bongo-lyrics--on-paused/resumed)
  (remove-hook 'bongo-player-sought-functions #'bongo-lyrics--on-sought)
  (when (overlayp bongo-lyrics--overlay)
    (delete-overlay bongo-lyrics--overlay))
  (let ((buffer (bongo-lyrics--lyrics-buffer)))
    (when buffer
      (kill-buffer buffer)))
  (setq bongo-lyrics--window nil
        bongo-lyrics--overlay nil
        bongo-lyrics--track-id nil
        bongo-lyrics--title ""
        bongo-lyrics--entries nil
        bongo-lyrics--plain nil
        bongo-lyrics--index nil
        bongo-lyrics--origin nil
        bongo-lyrics--paused-elapsed nil
        bongo-lyrics--line-cache nil))

;;;###autoload
(define-minor-mode bongo-lyrics-mode
  "Toggle synchronized lyrics display for Bongo.
This is a global minor mode; the lyrics follow whichever Bongo
playlist buffer currently has an active player."
  :global t
  :group 'bongo-lyrics
  (if bongo-lyrics-mode
      (progn
        (bongo-lyrics--setup-buffer)
        (bongo-lyrics--setup-controls)
        (bongo-lyrics--render-pending "No track playing")
        (add-hook 'bongo-player-started-hook #'bongo-lyrics--on-started)
        (add-hook 'bongo-player-stopped-hook #'bongo-lyrics--on-stopped)
        (add-hook 'bongo-player-paused/resumed-hook
                  #'bongo-lyrics--on-paused/resumed)
        (add-hook 'bongo-player-sought-functions #'bongo-lyrics--on-sought)
        (bongo-lyrics--update-track)
        (setq bongo-lyrics--timer
              (run-with-timer 0 bongo-lyrics-refresh-interval
                              #'bongo-lyrics--tick)))
    (bongo-lyrics--teardown)))

(provide 'bongo-lyrics)
;;; bongo-lyrics.el ends here
