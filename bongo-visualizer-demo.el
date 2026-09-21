;;; bongo-visualizer-demo.el --- self-contained Bongo visualizer demo -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Free Software Foundation, Inc.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A one-command demo of the Bongo visualizer.  It synthesises a short
;; audio file with ffmpeg if necessary, plays it with Bongo, and turns
;; on the C visualizer, which then reacts to the real audio in the mode
;; line.
;;
;; Run it with:
;;
;;   emacs -Q -l /path/to/bongo-visualizer-demo.el
;;
;; Keys:
;;   C-c v  cycle scope + spectrum, scope only, spectrum only
;;   C-c t  cycle the colour theme
;;   C-c p  pause or resume playback
;;   C-c q  stop playback and turn the visualizer off

;;; Code:

(require 'json)                 ; Bongo's mpv backend uses json-encode
(require 'bongo)
(require 'bongo-visualizer)

(defcustom bongo-visualizer-demo-file
  (expand-file-name "bongo-visualizer-demo.wav" temporary-file-directory)
  "Audio file used by `bongo-visualizer-demo'.  Generated if missing."
  :type 'file
  :group 'bongo-visualizer)

(defvar bongo-visualizer-demo--styles
  '((0 . "scope and spectrum") (1 . "scope") (2 . "spectrum"))
  "Visualizer styles offered by the demo.")

(defvar bongo-visualizer-demo--index 0)

(defun bongo-visualizer-demo--make-audio ()
  "Generate the demo audio file unless it already exists."
  (unless (file-exists-p bongo-visualizer-demo-file)
    (unless (executable-find "ffmpeg")
      (error "ffmpeg is needed to generate the demo audio"))
    (message "Generating %s..." bongo-visualizer-demo-file)
    (with-temp-buffer
      (unless (zerop
               (call-process "ffmpeg" nil t nil
                             "-v" "error" "-y" "-f" "lavfi" "-i"
                             (concat "aevalsrc="
                                     "0.40*sin(2*PI*(120+220*t)*t)"
                                     "+0.32*sin(2*PI*220*t)*(0.5+0.5*sin(2*PI*1.7*t))"
                                     "+0.26*sin(2*PI*440*t)*(0.5+0.5*sin(2*PI*2.6*t))"
                                     "+0.18*sin(2*PI*880*t)*(0.5+0.5*sin(2*PI*4.1*t))"
                                     ":s=44100:d=30")
                             "-ac" "1" "-ar" "8000"
                             bongo-visualizer-demo-file))
        (error "ffmpeg failed: %s" (buffer-string))))))

(defun bongo-visualizer-demo-play ()
  "Generate, enqueue and play the demo track, looping it."
  (interactive)
  (bongo-visualizer-demo--make-audio)
  (with-current-buffer (bongo-playlist-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))
    (goto-char (point-max))
    (bongo-insert-file bongo-visualizer-demo-file)
    (goto-char (point-min))
    (bongo-play)
    (bongo-repeating-playback-mode)))

(defun bongo-visualizer-demo-cycle-style ()
  "Switch to the next visualizer style."
  (interactive)
  (setq bongo-visualizer-demo--index
        (% (1+ bongo-visualizer-demo--index)
           (length bongo-visualizer-demo--styles)))
  (let ((style (nth bongo-visualizer-demo--index bongo-visualizer-demo--styles)))
    (setq bongo-visualizer-style (car style))
    (message "Visualizer style: %s" (cdr style))))

(defun bongo-visualizer-demo-stop ()
  "Stop playback and turn the visualizer off."
  (interactive)
  (ignore-errors (bongo-stop))
  (bongo-visualizer-mode -1)
  (message "Bongo visualizer demo stopped"))

;;;###autoload
(defun bongo-visualizer-demo ()
  "Play a generated track and show the Bongo visualizer reacting to it."
  (interactive)
  (setq bongo-visualizer-renderer 'module
        bongo-visualizer-source 'mpv
        bongo-visualizer-display 'mode-line
        bongo-visualizer-style 0
        bongo-visualizer-fps 30)
  (bongo-visualizer-mode 1)
  (bongo-visualizer-demo-play)
  (global-set-key (kbd "C-c v") #'bongo-visualizer-demo-cycle-style)
  (global-set-key (kbd "C-c t") #'bongo-visualizer-cycle-theme)
  (global-set-key (kbd "C-c p") #'bongo-pause/resume)
  (global-set-key (kbd "C-c q") #'bongo-visualizer-demo-stop)
  (message "Bongo visualizer demo: C-c v style, C-c t theme, C-c p pause, C-c q stop"))

;; Run immediately when loaded as a script, e.g. emacs -Q -l this-file.
;; Set BONGO_VISUALIZER_NO_AUTORUN in the environment to load the file
;; without starting the demo, for instance to drive it from emacsclient.
(unless (getenv "BONGO_VISUALIZER_NO_AUTORUN")
  (bongo-visualizer-demo))

(provide 'bongo-visualizer-demo)
;;; bongo-visualizer-demo.el ends here
