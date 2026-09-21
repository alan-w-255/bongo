;;; bongo-visualizer.el --- Music visualizer for Bongo using canvas images -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Free Software Foundation, Inc.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A music visualizer for Bongo, built on the `canvas' image type that
;; was added in Emacs 31 (see Info node `(elisp) Canvas Images').
;;
;; A canvas is an image object with a writable ARGB32 pixel buffer.  A
;; timer paints a frame into that buffer and calls `canvas-refresh', so
;; no new Lisp object is allocated per frame.
;;
;; There are two renderers:
;;
;;   module  The C module `bongo-visualizer-module' computes a Hann
;;           windowed FFT and draws the frame pixels-first on the CPU,
;;           in the spirit of the Sonic Pi scope and spectrum views,
;;           in a pink phosphor palette.  This is the default whenever
;;           the module has been built.
;;
;;   Lisp    A pure-Lisp fallback that needs no compiler at all.
;;
;; Where do the samples come from?  Bongo itself just launches external
;; players; it does not see the audio.  So this module decodes the
;; currently playing file with `mpv --ao=pcm' into a PCM pipe once per
;; track and indexes into it using `bongo-elapsed-time'.  If that is
;; unavailable, it falls back to a procedural "demo" animation.
;;
;; Usage:
;;   M-x bongo-visualizer-build-module RET   (once, compiles the C module)
;;   (require 'bongo-visualizer)
;;   (bongo-visualizer-mode 1)
;;
;;   M-x bongo-visualizer-cycle-theme RET    (switch colour themes)
;;
;; The C renderer is a dynamic module; without it a slower pure-Lisp
;; renderer is used.
;;
;; In the mode line the canvas height defaults to the height of the mode
;; line itself (see `bongo-visualizer-mode-line-height'), so that it
;; fills it; run `M-x bongo-visualizer-refit' after changing the font
;; size or if you set an explicit height.  The canvas background is
;; transparent by default (see
;; `bongo-visualizer-transparent-background'), so the mode line colour
;; shows through and only the glowing waveform and spectrum are drawn.
;;
;; The visualizer follows whichever Bongo playlist buffer has an active
;; player.  By default it is shown in the mode line of every buffer (see
;; `bongo-visualizer-display'); set that to `side-window' to put it in a
;; dedicated buffer at the bottom of the frame instead.  The player
;; buffer of `bongo-player-mode' draws its own, independent view, so the
;; two do not share a canvas and can run at the same time.
;;
;; The colours come from `bongo-visualizer-theme'; use
;; `bongo-visualizer-cycle-theme' to step through the built-in themes or
;; `bongo-visualizer-set-theme' to pick one by name.  Adding a theme is
;; just a matter of pushing another entry onto `bongo-visualizer-themes'.

;;; Code:

(require 'bongo)
(require 'cl-lib)
(require 'subr-x)

(defconst bongo-visualizer--directory
  (let* ((this (or load-file-name buffer-file-name))
         (dir (file-name-directory this))
         ;; straight.el loads packages from a build directory whose `.el'
         ;; files are symlinks into the checkout.  Resolve the symlink so
         ;; that the C source, the Makefile and the built module can be
         ;; found next to the real file rather than next to the `.elc'.
         (source (expand-file-name "bongo-visualizer.el" dir))
         (file (if (file-exists-p source) source this)))
    (file-name-directory (file-truename file)))
  "Directory containing `bongo-visualizer.el'.")

(defun bongo-visualizer--source-directory ()
  "Return the directory holding the Makefile and the C source.
When the library was loaded from a straight.el build directory this
resolves the build symlink back into the package checkout."
  (or (cl-find-if
       (lambda (dir)
         (and dir
              (file-exists-p (expand-file-name "Makefile.bongo-visualizer"
                                               dir))))
       (list bongo-visualizer--directory
             (let ((el (expand-file-name "bongo-visualizer.el"
                                         bongo-visualizer--directory)))
               (and (file-exists-p el)
                    (file-name-directory (file-truename el))))))
      bongo-visualizer--directory))

;; Provided at runtime by the optional C module (see the Makefile).
(declare-function bongo-vis-render "bongo-visualizer-module"
                  (canvas samples width height rate time &optional style
                          transparent theme slot))
(declare-function bongo-vis-reset "bongo-visualizer-module" ())
(declare-function bongo-vis-spectrum "bongo-visualizer-module"
                  (samples rate bins))
(declare-function bongo-vis-waveform "bongo-visualizer-module"
                  (samples bins))

(defgroup bongo-visualizer nil
  "Music visualizer for Bongo."
  :group 'bongo
  :prefix "bongo-visualizer-")

(defcustom bongo-visualizer-width 360
  "Width of the visualizer canvas, in pixels."
  :type 'integer)

(defcustom bongo-visualizer-height 100
  "Height of the visualizer canvas, in pixels."
  :type 'integer)

(defcustom bongo-visualizer-display 'mode-line
  "Where to display the visualizer.
`mode-line' puts the canvas in `global-mode-string', so that it shows
in the mode line of every buffer.  `side-window' shows it in a
dedicated buffer in a side window instead."
  :type '(choice (const :tag "Mode line" mode-line)
                 (const :tag "Side window" side-window)))

(defcustom bongo-visualizer-transparent-background t
  "Whether the visualizer canvas has a transparent background.
This is what you want in the mode line: the mode line colour shows
through and only the glowing waveform and spectrum are drawn.  Set it
to nil for the opaque dark background of the separate buffer."
  :type 'boolean)

(defcustom bongo-visualizer-mode-line-width 240
  "Displayed width in pixels of the visualizer in the mode line.
The canvas is scaled by `bongo-visualizer-scale'."
  :type 'integer)

(defcustom bongo-visualizer-mode-line-height nil
  "Displayed height in pixels of the visualizer in the mode line.
If nil, match the height of the mode line of the selected window, so
that the visualizer fills it.  Set it to an integer to force a size.
The canvas is scaled by `bongo-visualizer-scale'."
  :type '(choice (const :tag "Fit the mode line" nil)
                 integer))

(defcustom bongo-visualizer-ascent 'center
  "Ascent used when displaying the canvas image.
The default `center' vertically centers the canvas on the surrounding
text (as Bongo's own track icons do), so that it lines up with the mode
line text.  A number in 0..100 is interpreted as that percentage of the
image height above the baseline, which is how Emacs places images by
default; 50 therefore puts the image's center on the baseline and makes
it look too low.  A number may be useful to fine-tune the alignment if
the mode line has a box or unusual padding."
  :type '(choice (const :tag "Center on text" center)
                 integer))

(defcustom bongo-visualizer-scale 1
  "Scale factor for the displayed canvas image.
On HiDPI/Retina displays you may want 0.5 so the image is not huge."
  :type 'number)

(defcustom bongo-visualizer-fps 30
  "Frames per second for the visualizer animation."
  :type 'integer)

(defcustom bongo-visualizer-bands 24
  "Number of spectrum bars."
  :type 'integer)

(defcustom bongo-visualizer-lowest-frequency 60.0
  "Lowest centre frequency analyzed, in Hz."
  :type 'number)

(defcustom bongo-visualizer-sample-rate 8000
  "Sample rate used when decoding audio with mpv.
The Nyquist frequency is half of this, and is the highest band."
  :type 'integer)

(defcustom bongo-visualizer-window 512
  "Number of samples (per band) used for each spectrum estimate.
Bigger is more frequency-selective but slower: the Goertzel loop runs
`bands' times over this many samples on every frame."
  :type 'integer)

(defcustom bongo-visualizer-source 'mpv
  "Where the visualizer gets its data from.
`mpv' decodes the playing file with `--ao=pcm' and computes a real
spectrum.  `demo' ignores the audio and draws a procedural animation."
  :type '(choice (const :tag "Decode with mpv" mpv)
                 (const :tag "Procedural demo" demo)))

(defcustom bongo-visualizer-use-module t
  "Whether to use the optional C dynamic module when it is available.
The module does the FFT and the rendering in C and writes straight into
the canvas pixel buffer, which is much faster and much prettier than
the pure-Lisp fallback.  See `bongo-visualizer-module-file'."
  :type 'boolean)

(defcustom bongo-visualizer-module-file nil
  "Path of the visualizer dynamic module.
If nil, look for `bongo-visualizer-module' next to this file."
  :type '(choice (const :tag "Next to bongo-visualizer.el" nil)
                 file))

(defcustom bongo-visualizer-style 0
  "Visual style used by the built-in C software renderer.
Following the Sonic Pi visualisers, the choices are a scope (the green
oscilloscope), a spectrum (the rainbow analyser wings), or both."
  :type '(choice (const :tag "Scope and spectrum" 0)
                 (const :tag "Scope only" 1)
                 (const :tag "Spectrum only" 2)))

(defcustom bongo-visualizer-renderer 'auto
  "Which engine draws the frames.
`auto' prefers the built-in C renderer and falls back to pure Lisp.
`module' and `lisp' force one of them."
  :type '(choice (const :tag "Prefer C" auto)
                 (const :tag "C software renderer" module)
                 (const :tag "Pure Lisp" lisp)))

(defcustom bongo-visualizer-mpv-program "mpv"
  "Name of the mpv executable."
  :type 'string)

(defcustom bongo-visualizer-mpv-arguments
  '("--no-config" "--no-video" "--really-quiet")
  "Arguments passed to mpv before the format options and FILE.
`--no-config' must stay first for it to take effect; it keeps the
user's configuration from interfering with this background decoder,
for example by making it claim the player's IPC socket."
  :type '(repeat string))

(defcustom bongo-visualizer-latency 0.15
  "How many seconds to look behind the reported playback time.
Compensates for the delay between `bongo-elapsed-time' and what you
actually hear, and makes sure mpv has decoded that far."
  :type 'number)

(defcustom bongo-visualizer-decay 0.80
  "Per-frame decay factor for bar levels (1.0 freezes, 0.0 is instant)."
  :type 'number)

(defcustom bongo-visualizer-db-offset 55.0
  "Number of dB added before mapping power to a bar height."
  :type 'number)

(defcustom bongo-visualizer-db-range 60.0
  "Dynamic range, in dB, that maps to the full bar height."
  :type 'number)

(defcustom bongo-visualizer-peaks t
  "Whether to draw falling peak caps above each bar."
  :type 'boolean)

(defcustom bongo-visualizer-buffer-name "*Bongo Visualizer*"
  "Name of the buffer holding the visualizer canvas."
  :type 'string)

(defcustom bongo-visualizer-side 'bottom
  "Side used to display the visualizer window.
One of `bottom', `top', `left', `right', or nil to reuse any window."
  :type '(choice (const bottom) (const top) (const left) (const right)
                 (const :tag "Any window" nil)))


;;;; Colors

(defsubst bongo-visualizer--argb (r g b &optional a)
  "Pack A, R, G, B bytes into an ARGB32 fixnum.
R, G and B are clamped to 0..255; A defaults to fully opaque."
  (let ((clamp (lambda (x) (max 0 (min 255 (round x))))))
    (logior (ash (funcall clamp (or a 255)) 24)
            (ash (funcall clamp r) 16)
            (ash (funcall clamp g) 8)
            (funcall clamp b))))

(defconst bongo-visualizer-themes
  '((pink
     :label "Pink phosphor"
     :hue (0.94 0.85)
     :sat (0.85 0.55)
     :envelope (1.8 1.15 1.55)
     :peak (2.3 1.5 2.0)
     :scope (1.0 0.28 0.62)
     :axis (0.32 0.08 0.18)
     :background (12 14 22)
     :grid (28 32 48)
     :gradient ((30 4 26) (140 10 80) (225 60 145) (255 205 235))
     :caps (250 215 240))
    (green
     :label "Green phosphor"
     :hue (0.33 0.45)
     :sat (0.90 0.55)
     :envelope (0.85 1.85 1.05)
     :peak (1.2 2.3 1.5)
     :scope (0.25 1.0 0.42)
     :axis (0.06 0.30 0.12)
     :background (10 18 12)
     :grid (24 44 28)
     :gradient ((2 30 10) (10 120 40) (60 210 110) (200 255 215))
     :caps (210 255 220))
    (amber
     :label "Amber CRT"
     :hue (0.07 0.13)
     :sat (0.95 0.60)
     :envelope (1.95 1.35 0.6)
     :peak (2.35 1.7 0.85)
     :scope (1.0 0.58 0.10)
     :axis (0.32 0.16 0.02)
     :background (20 14 8)
     :grid (46 32 14)
     :gradient ((36 16 2) (140 70 6) (225 150 30) (255 235 180))
     :caps (255 230 170))
    (cyan
     :label "Ice cyan"
     :hue (0.50 0.62)
     :sat (0.85 0.55)
     :envelope (0.7 1.65 1.9)
     :peak (0.9 1.95 2.3)
     :scope (0.2 0.82 1.0)
     :axis (0.05 0.22 0.30)
     :background (8 16 22)
     :grid (18 36 48)
     :gradient ((2 26 34) (6 100 130) (40 190 220) (200 250 255))
     :caps (205 250 255))
    (blue
     :label "Deep blue"
     :hue (0.62 0.72)
     :sat (0.90 0.60)
     :envelope (0.6 0.95 2.0)
     :peak (0.85 1.25 2.4)
     :scope (0.3 0.5 1.0)
     :axis (0.06 0.12 0.36)
     :background (8 10 26)
     :grid (20 26 56)
     :gradient ((2 4 40) (10 30 140) (50 110 235) (190 220 255))
     :caps (195 220 255))
    (rainbow
     :label "Rainbow spectrum"
     :hue (0.0 0.85)
     :sat (0.90 0.90)
     :envelope (1.7 1.7 1.7)
     :peak (2.3 2.3 2.3)
     :scope (1.0 0.55 0.12)
     :axis (0.22 0.22 0.24)
     :background (10 10 14)
     :grid (30 30 40)
     :gradient ((60 0 120) (0 120 230) (0 200 90) (255 180 0))
     :caps (255 255 255))
    (mono
     :label "Monochrome"
     :hue (0.60 0.60)
     :sat (0.0 0.0)
     :envelope (1.8 1.85 2.0)
     :peak (2.4 2.45 2.6)
     :scope (0.9 0.93 1.0)
     :axis (0.2 0.22 0.30)
     :background (12 12 16)
     :grid (34 34 44)
     :gradient ((20 20 26) (90 92 105) (170 175 190) (245 248 255))
     :caps (250 252 255)))
  "Colour themes for the Bongo visualizer.

Each element has the form (ID . PLIST).  ID is a symbol naming the
theme; the plist holds:

  :label       Human readable name.
  :hue         (START END), HSV hue at the low and high ends of the
               spectrum, both in 0..1.
  :sat         (START END), the matching HSV saturations.
  :envelope    HDR RGB of the bright spectrum edge (C module).
  :peak        HDR RGB of the falling peak caps (C module).
  :scope       HDR RGB of the oscilloscope trace (C module).
  :axis        HDR RGB of the scope's zero axis (C module).
  :background  RGB bytes of the opaque background.
  :grid        RGB bytes of the graticule lines.
  :gradient    RGB byte colours from the bottom of a bar to its top,
               used by the pure-Lisp renderer.
  :caps        RGB bytes of the pure-Lisp renderer's peak caps.

The C module receives the first eight groups as a flat float vector;
see `bongo-visualizer--theme-vector'.")

(defcustom bongo-visualizer-theme 'pink
  "Colour theme used by the visualizer.
See `bongo-visualizer-themes' for the choices.  Prefer
`bongo-visualizer-set-theme' or `bongo-visualizer-cycle-theme' to
switch themes; `customize-set-variable' works as well.  Setting the
value directly with `setq' takes effect on the next animation frame."
  :type `(choice
          ,@(mapcar (lambda (entry)
                      `(const :tag ,(plist-get (cdr entry) :label)
                              ,(car entry)))
                    bongo-visualizer-themes)))

(defun bongo-visualizer--theme (&optional theme)
  "Return the plist describing THEME, defaulting to the selected theme.
Unknown names fall back to `pink'."
  (or (cdr (assq (or theme bongo-visualizer-theme) bongo-visualizer-themes))
      (cdr (assq 'pink bongo-visualizer-themes))))

(defun bongo-visualizer--theme-argb (key &optional alpha)
  "Pack the current theme's RGB color stored under KEY into ARGB32."
  (let ((rgb (plist-get (bongo-visualizer--theme) key)))
    (bongo-visualizer--argb (nth 0 rgb) (nth 1 rgb) (nth 2 rgb) alpha)))

(defun bongo-visualizer--blend-rgb (a b frac)
  "Blend RGB byte colors A and B by FRAC (0 gives A, 1 gives B)."
  (bongo-visualizer--argb
   (+ (* (nth 0 a) (- 1.0 frac)) (* (nth 0 b) frac))
   (+ (* (nth 1 a) (- 1.0 frac)) (* (nth 1 b) frac))
   (+ (* (nth 2 a) (- 1.0 frac)) (* (nth 2 b) frac))))

(defun bongo-visualizer--theme-gradient-vector (height)
  "Build a HEIGHT-long ARGB gradient from the current theme's stops."
  (let* ((stops (plist-get (bongo-visualizer--theme) :gradient))
         (n (length stops)))
    (vconcat
     (cl-loop for dy below height
              for frac = (if (> height 1) (/ (float dy) (1- height)) 0.0)
              for pos = (* frac (1- n))
              for i = (min (1- n) (floor pos))
              for j = (min (1- n) (1+ i))
              collect (bongo-visualizer--blend-rgb
                       (nth i stops) (nth j stops)
                       (if (= i j) 0.0 (- pos i)))))))

(defun bongo-visualizer--theme-vector (&optional theme)
  "Return the flat float vector that the C renderer uses for THEME.
The order of the components is documented in
`bongo-visualizer-themes'."
  (let* ((plist (bongo-visualizer--theme theme))
         (hue (plist-get plist :hue))
         (sat (plist-get plist :sat)))
    (vconcat
     (mapcar #'float
             (append hue sat
                     (plist-get plist :envelope)
                     (plist-get plist :peak)
                     (plist-get plist :scope)
                     (plist-get plist :axis)
                     (plist-get plist :background)
                     (plist-get plist :grid))))))


;;;; Canvas state

(defvar bongo-visualizer-mode)  ; defined by `define-minor-mode' below

(cl-defstruct (bongo-visualizer--view
               (:constructor bongo-visualizer--make-view)
               (:copier nil))
  "State of one visualizer canvas.
A view owns its image, dimensions, background, colour snapshot and
smoothing state, so the mode-line visualizer and the player-buffer
visualizer do not share anything but the decoded audio."
  (slot 0 :type integer)
  (display 'mode-line :type symbol)
  canvas
  width
  height
  data
  background
  gradient
  peak-color
  c-theme
  current-theme
  levels
  peaks
  buffer)

(defvar bongo-visualizer--views nil
  "List of visualizer views that currently own a canvas.")
(defvar bongo-visualizer--mode-line-view nil
  "The view shown by `bongo-visualizer-mode', or nil.")
(defvar bongo-visualizer--timer nil
  "Repeating timer driving the animation of the mode-line view.")

(defun bongo-visualizer--free-slot ()
  "Return the lowest C module slot not used by a live view."
  (let ((used (mapcar #'bongo-visualizer--view-slot bongo-visualizer--views)))
    (or (cl-find-if-not (lambda (slot) (memq slot used)) '(0 1))
        0)))

(defun bongo-visualizer--new-view (display)
  "Create a visualizer view for DISPLAY."
  (bongo-visualizer--make-view
   :display display
   :slot (bongo-visualizer--free-slot)))


;;;; PCM source

(defvar bongo-visualizer--pcm-buffer nil
  "Unibyte buffer accumulating raw little-endian s16 samples.")
(defvar bongo-visualizer--pcm-process nil
  "The mpv decoding process.")
(defvar bongo-visualizer--current-file nil
  "File currently being decoded.")

(defun bongo-visualizer--pcm-available ()
  "Return the number of bytes available in the PCM buffer, or 0."
  (if (and bongo-visualizer--pcm-buffer
           (buffer-live-p bongo-visualizer--pcm-buffer))
      (with-current-buffer bongo-visualizer--pcm-buffer
        ;; `buffer-size' is the number of bytes in this unibyte buffer.
        (buffer-size))
    0))

(defun bongo-visualizer--stop-pcm ()
  "Kill the decoding process and discard its buffer."
  (when (and bongo-visualizer--pcm-process
             (process-live-p bongo-visualizer--pcm-process))
    (delete-process bongo-visualizer--pcm-process))
  (setq bongo-visualizer--pcm-process nil
        bongo-visualizer--current-file nil)
  (when (and bongo-visualizer--pcm-buffer
             (buffer-live-p bongo-visualizer--pcm-buffer))
    (kill-buffer bongo-visualizer--pcm-buffer))
  (setq bongo-visualizer--pcm-buffer nil))

(defun bongo-visualizer--start-pcm (file)
  "Start decoding FILE to raw PCM with mpv."
  (bongo-visualizer--stop-pcm)
  (let* ((rate bongo-visualizer-sample-rate)
         (buffer (generate-new-buffer " *bongo-visualizer-pcm*")))
    ;; The buffer must be unibyte *before* any process output arrives, and
    ;; the process must never decode the bytes; `make-process' lets us set
    ;; both up front.  Otherwise byte offsets and character positions
    ;; diverge and the samples get mangled.
    (with-current-buffer buffer
      (set-buffer-multibyte nil))
    (let ((process
           (make-process
            :name "bongo-visualizer-mpv"
            :buffer buffer
            ;; Do NOT let stderr share the stdout buffer: mpv writes
            ;; diagnostics there even with `--really-quiet', and a single
            ;; stray byte shifts every sample and destroys the spectrum.
            :stderr (get-buffer-create " *bongo-visualizer-mpv-stderr*")
            ;; mpv spells the sample format without an endianness suffix;
            ;; s16 is little-endian, as `bongo-visualizer--pcm-samples'
            ;; assumes, on the platforms Emacs canvas images target.
            :command (append (list bongo-visualizer-mpv-program)
                             bongo-visualizer-mpv-arguments
                             (list "--ao=pcm"
                                   "--ao-pcm-waveheader=no"
                                   ;; mpv has no `-' convention here; this
                                   ;; streams the PCM to stdout on POSIX.
                                   "--ao-pcm-file=/dev/stdout"
                                   "--audio-format=s16"
                                   (format "--audio-samplerate=%d" rate)
                                   "--audio-channels=mono"
                                   "--"
                                   file))
            :coding 'no-conversion
            :connection-type 'pipe
            :sentinel #'ignore
            :noquery t)))
      (setq bongo-visualizer--pcm-buffer buffer
            bongo-visualizer--pcm-process process
            bongo-visualizer--current-file file))))

(defun bongo-visualizer--ensure-source (player)
  "Make sure the PCM source matches what PLAYER is playing."
  (when (eq bongo-visualizer-source 'mpv)
    (let ((file (ignore-errors (bongo-player-file-name player))))
      (when (and (stringp file)
                 (not (equal file bongo-visualizer--current-file)))
        (condition-case err
            (bongo-visualizer--start-pcm file)
          (error
           (message "bongo-visualizer: mpv failed: %s"
                    (error-message-string err))))))))

(defun bongo-visualizer--pcm-samples (n)
  "Return a vector of N floats in [-1, 1] ending at the playback position.
Return nil if no PCM data is available (yet)."
  (let ((available (bongo-visualizer--pcm-available)))
    (when (> available 4)
      (let* ((rate bongo-visualizer-sample-rate)
             (time (- (or (bongo-elapsed-time) 0.0)
                      bongo-visualizer-latency))
             (center (round (* time rate)))
             (start (max 0 (- center (/ n 2))))
             (start-byte (* 2 start))
             (end-byte (min available (+ start-byte (* 2 n)))))
        (when (> (- end-byte start-byte) 4)
          (with-current-buffer bongo-visualizer--pcm-buffer
            (let* ((raw (buffer-substring-no-properties (1+ start-byte)
                                                        (1+ end-byte)))
                   (length (length raw))
                   (samples (make-vector n 0.0))
                   (i 0)
                   (j 0))
              (while (and (< j n) (< (1+ i) length))
                (let ((value (logior (aref raw i)
                                     (ash (aref raw (1+ i)) 8))))
                  (when (>= value 32768)
                    (setq value (- value 65536)))
                  (aset samples j (/ value 32768.0)))
                (setq i (+ i 2)
                      j (1+ j)))
              samples)))))))


;;;; Spectrum analysis

(defun bongo-visualizer--band-frequencies (n rate)
  "Return N log-spaced frequencies between the low bound and RATE's Nyquist."
  (let ((low bongo-visualizer-lowest-frequency)
        (high (* 0.5 rate)))
    (cl-loop for i from 0 below n
             collect (* low (expt (/ high low)
                                 (/ (float i) (max 1 (1- n))))))))

(defun bongo-visualizer--goertzel (samples frequency rate)
  "Return the power of FREQUENCY in SAMPLES sampled at RATE.
This is the Goertzel algorithm: a single-bin DFT, so we only pay for
the bins we actually display."
  (let* ((n (length samples))
         (k (/ (* frequency n) rate))
         (w (/ (* 2.0 float-pi k) n))
         (coefficient (* 2.0 (cos w)))
         (s-prev 0.0)
         (s-prev2 0.0))
    (dotimes (i n)
      (let ((s (+ (aref samples i)
                  (* coefficient s-prev)
                  (- s-prev2))))
        (setq s-prev2 s-prev
              s-prev s)))
    (+ (* s-prev s-prev)
       (* s-prev2 s-prev2)
       (- (* coefficient s-prev s-prev2)))))

(defun bongo-visualizer--power-to-level (power n)
  "Convert Goertzel POWER over N samples to a bar height in 0..1."
  (let* ((amplitude (/ (sqrt (max 0.0 power)) (float n)))
         (db (+ (* 20.0 (log (max amplitude 1e-6) 10.0))
                bongo-visualizer-db-offset))
         (level (/ db bongo-visualizer-db-range)))
    (max 0.0 (min 1.0 level))))

(defun bongo-visualizer--demo-levels ()
  "Return a procedural spectrum, used when no PCM data is available."
  (let ((time (float-time))
        (n bongo-visualizer-bands))
    (cl-loop for i below n
             collect (max 0.0 (min 1.0
                                   (* 0.55
                                      (+ 1.0
                                         (sin (+ (* time (+ 1.0 (/ i 4.0)))
                                                 (* i 0.7)))
                                         (* 0.3 (sin (* time 3.7 i))))))))))

(defun bongo-visualizer--demo-samples ()
  "Return a window of synthetic PCM for the C module's demo mode."
  (let* ((n bongo-visualizer-window)
         (rate (float bongo-visualizer-sample-rate))
         (t0 (float-time))
         (samples (make-vector n 0.0)))
    (dotimes (i n)
      (let ((tt (+ t0 (/ i rate))))
        (aset samples i
              (* 0.45 (+ (sin (* 2.0 float-pi 220.0 tt))
                         (* 0.6 (sin (* 2.0 float-pi 440.0 tt)))
                         (* 0.35 (sin (* 2.0 float-pi 660.0 tt))))))))
    samples))

(defun bongo-visualizer--compute-levels ()
  "Compute the raw bar levels for the current frame."
  (if (eq bongo-visualizer-source 'demo)
      (bongo-visualizer--demo-levels)
    (let ((samples (bongo-visualizer--pcm-samples bongo-visualizer-window)))
      (if (null samples)
          (bongo-visualizer--demo-levels)
        (let ((rate bongo-visualizer-sample-rate)
              (n (length samples)))
          (mapcar (lambda (frequency)
                    (bongo-visualizer--power-to-level
                     (bongo-visualizer--goertzel samples frequency rate)
                     n))
                  (bongo-visualizer--band-frequencies
                   bongo-visualizer-bands rate)))))))

(defun bongo-visualizer--smooth (new old)
  "Blend NEW levels with OLD ones using `bongo-visualizer-decay'."
  (if (or (null old) (/= (length new) (length old)))
      new
    (cl-mapcar (lambda (n o) (max n (* o bongo-visualizer-decay)))
               new old)))

(defun bongo-visualizer--track-peaks (levels view)
  "Update and return falling peak positions for LEVELS in VIEW."
  (let ((old (bongo-visualizer--view-peaks view))
        (height (or (bongo-visualizer--view-height view)
                    bongo-visualizer-height)))
    (setf (bongo-visualizer--view-peaks view)
          (cl-mapcar (lambda (level peak)
                       (let ((peak (or peak 0.0)))
                         (cond ((>= level peak) level)
                               (t (max 0.0 (- peak (/ 1.0 height)))))))
                     levels
                     (if (and old (= (length old) (length levels)))
                         old
                       (make-list (length levels) 0.0))))))


;;;; Rendering

(defun bongo-visualizer--mode-line-canvas-height ()
  "Return the pixel height to use for the mode line visualizer canvas."
  (or (and (integerp bongo-visualizer-mode-line-height)
           bongo-visualizer-mode-line-height)
      (let ((height (and (fboundp 'window-mode-line-height)
                         (window-live-p (selected-window))
                         (window-mode-line-height))))
        (if (and height (> height 1))
            height
          (frame-char-height)))))

(defun bongo-visualizer--setup-canvas (view)
  "Create the canvas image and its background vector for VIEW."
  ;; Drop the previous canvas from the frame image caches, so that its
  ;; image object and pixmap are freed instead of lingering as long as
  ;; the frame lives.
  (when (bongo-visualizer--view-canvas view)
    (image-flush (bongo-visualizer--view-canvas view) t))
  (let* ((scale (if (and (numberp bongo-visualizer-scale)
                         (> bongo-visualizer-scale 0))
                    bongo-visualizer-scale
                  1.0))
         (mode-line (eq (bongo-visualizer--view-display view) 'mode-line))
         (width (if mode-line
                    (round (/ bongo-visualizer-mode-line-width scale))
                  bongo-visualizer-width))
         (height (if mode-line
                     (round (/ (bongo-visualizer--mode-line-canvas-height)
                               scale))
                   bongo-visualizer-height))
         (background-color (if bongo-visualizer-transparent-background
                               (bongo-visualizer--argb 0 0 0 1)
                             (bongo-visualizer--theme-argb :background)))
         (grid-color (if bongo-visualizer-transparent-background
                         (bongo-visualizer--argb 0 0 0 1)
                       (bongo-visualizer--theme-argb :grid)))
         (background (make-vector (* width height)
                                  background-color)))
    ;; A couple of horizontal grid lines for depth.
    (dotimes (i height)
      (when (zerop (mod i (max 1 (/ height 4))))
        (dotimes (x width)
          (aset background (+ (* i width) x) grid-color))))
    ;; Do not pass an explicit `:id': `create-image' gives each canvas a
    ;; unique id, so a canvas recreated later can never alias a cached
    ;; one in the frame image cache.
    (let ((canvas (create-image (copy-sequence background) 'canvas t
                                :data-width width
                                :data-height height
                                :scale bongo-visualizer-scale
                                :ascent bongo-visualizer-ascent)))
      (setf (bongo-visualizer--view-width view) width
            (bongo-visualizer--view-height view) height
            (bongo-visualizer--view-background view) background
            (bongo-visualizer--view-gradient view)
            (bongo-visualizer--theme-gradient-vector height)
            (bongo-visualizer--view-peak-color view)
            (bongo-visualizer--theme-argb :caps)
            (bongo-visualizer--view-c-theme view)
            (bongo-visualizer--theme-vector)
            (bongo-visualizer--view-current-theme view) bongo-visualizer-theme
            (bongo-visualizer--view-canvas view) canvas
            (bongo-visualizer--view-data view) (plist-get (cdr canvas) :data)
            (bongo-visualizer--view-levels view) nil
            (bongo-visualizer--view-peaks view) nil))
    (cl-pushnew view bongo-visualizer--views :test #'eq)))

(defun bongo-visualizer--refresh-view (view)
  "Refresh the display that shows VIEW's canvas after a rebuild."
  (if (eq (bongo-visualizer--view-display view) 'mode-line)
      (force-mode-line-update t)
    (let ((buffer (bongo-visualizer--view-buffer view)))
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (propertize " " 'display
                                (bongo-visualizer--view-canvas view)))
            (insert "\n")
            (goto-char (point-min))))))))

(defun bongo-visualizer--apply-theme-change ()
  "Rebuild every live canvas for the current theme."
  (dolist (view bongo-visualizer--views)
    (bongo-visualizer--setup-canvas view)
    (bongo-visualizer--refresh-view view)))

(defun bongo-visualizer--destroy-view (view)
  "Release VIEW: flush its canvas, kill its buffer and unregister it.
When no view remains, also stop the PCM decoder and forget the C
module state."
  (when view
    (when (bongo-visualizer--view-canvas view)
      (image-flush (bongo-visualizer--view-canvas view) t))
    (let ((buffer (bongo-visualizer--view-buffer view)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))
    (setf (bongo-visualizer--view-canvas view) nil
          (bongo-visualizer--view-data view) nil
          (bongo-visualizer--view-buffer view) nil)
    (setq bongo-visualizer--views (delq view bongo-visualizer--views))
    (unless bongo-visualizer--views
      (bongo-visualizer--stop-pcm)
      (when (fboundp 'bongo-vis-reset)
        (bongo-vis-reset)))))

(defun bongo-visualizer-cycle-theme (&optional n)
  "Switch to the next visualizer color theme.
With prefix argument N, move N themes forward; a negative N moves
backwards."
  (interactive "p")
  (let* ((ids (mapcar #'car bongo-visualizer-themes))
         (step (or n 1))
         (index (or (cl-position bongo-visualizer-theme ids) 0))
         (next (nth (% (+ index step) (length ids)) ids)))
    (setq bongo-visualizer-theme next)
    (when bongo-visualizer--views
      (bongo-visualizer--apply-theme-change))
    (message "Bongo visualizer theme: %s"
             (plist-get (bongo-visualizer--theme next) :label))))

;;;###autoload
(defun bongo-visualizer-set-theme (theme)
  "Choose the visualizer color THEME by name.
Interactively, prompt for one of `bongo-visualizer-themes'."
  (interactive
   (list (intern
          (completing-read
           "Visualizer theme: "
           (mapcar (lambda (entry)
                     (cons (plist-get (cdr entry) :label) (car entry)))
                   bongo-visualizer-themes)
           nil t))))
  (setq bongo-visualizer-theme theme)
  (when bongo-visualizer--views
    (bongo-visualizer--apply-theme-change))
  (message "Bongo visualizer theme: %s"
           (plist-get (bongo-visualizer--theme theme) :label)))

(defun bongo-visualizer--render (levels view)
  "Paint LEVELS onto VIEW's canvas and refresh it."
  (let ((canvas (bongo-visualizer--view-canvas view))
        (data (bongo-visualizer--view-data view)))
    (when (and canvas data)
      (let* ((width (or (bongo-visualizer--view-width view)
                        bongo-visualizer-width))
             (height (or (bongo-visualizer--view-height view)
                         bongo-visualizer-height))
             (bands (max 1 (length levels)))
             (bar-width (max 1 (/ width bands)))
             (gap (if (>= bar-width 4) 1 0))
             (smooth-levels levels))
        ;; Start from a pristine background: this is a C-level vector
        ;; copy, much faster than clearing pixel by pixel from Lisp.
        (setq data (copy-sequence (bongo-visualizer--view-background view)))
        (setf (bongo-visualizer--view-data view) data)
        (plist-put (cdr canvas) :data data)
        (cl-loop for level in smooth-levels
                 for band from 0
                 for x0 = (* band bar-width)
                 for bar-height = (min height
                                       (round (* (max 0.0 (min 1.0 level))
                                                 (- height 2))))
                 do (dotimes (dx (max 0 (- bar-width gap)))
                      (let ((x (+ x0 dx)))
                        (when (< x width)
                          (dotimes (dy bar-height)
                            (let ((y (- height 1 dy)))
                              (aset data (+ (* y width) x)
                                    (aref (bongo-visualizer--view-gradient view)
                                          dy))))
                          (when bongo-visualizer-peaks
                            (let* ((peak
                                    (or (nth band
                                             (bongo-visualizer--view-peaks
                                              view))
                                        0.0))
                                   (py (- height 1
                                          (min (1- height)
                                               (round (* peak
                                                         (- height 2)))))))
                              (when (>= py 0)
                                (aset data (+ (* py width) x)
                                      (bongo-visualizer--view-peak-color
                                       view)))))))))
        (canvas-refresh canvas 'reload-data)))))


;;;; The frame loop

(defun bongo-visualizer--player ()
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

(defun bongo-visualizer--module-active-p ()
  "Return non-nil if the C module should draw the frames."
  (and bongo-visualizer-use-module
       (fboundp 'bongo-vis-render)))

(defun bongo-visualizer-build-module ()
  "Compile the C renderer module with `make'.
Run this once before enabling `bongo-visualizer-mode', or after editing
`bongo-visualizer-module.c'."
  (interactive)
  (let ((default-directory (bongo-visualizer--source-directory)))
    (compile (format "make -f %s"
                     (shell-quote-argument
                      (expand-file-name "Makefile.bongo-visualizer"
                                        default-directory))))))

(defun bongo-visualizer-refit ()
  "Resize the mode-line visualizer canvas to fit the mode line.
Run this after changing the font size or the mode line height."
  (interactive)
  (let ((view bongo-visualizer--mode-line-view))
    (if (not (and bongo-visualizer-mode view))
        (message "Bongo visualizer is not enabled")
      (bongo-visualizer--setup-canvas view)
      (bongo-visualizer--refresh-view view)
      (message "Bongo visualizer: canvas is now %dx%d"
               (bongo-visualizer--view-width view)
               (bongo-visualizer--view-height view)))))

(defun bongo-visualizer--load-module ()
  "Load the C module if it can be found.  Return non-nil if available."
  (or (fboundp 'bongo-vis-render)
      (when bongo-visualizer-use-module
        (let* ((dir (bongo-visualizer--source-directory))
               (file (or bongo-visualizer-module-file
                         (expand-file-name
                          (concat "bongo-visualizer-module" module-file-suffix)
                          dir))))
          (cond
           ((file-exists-p file)
            (condition-case err
                (progn (module-load file) t)
              (error
               (message "bongo-visualizer: cannot load %s: %s"
                        file (error-message-string err))
               nil)))
           ((file-exists-p (expand-file-name "Makefile.bongo-visualizer" dir))
            (message "bongo-visualizer: %s is not built; run %s"
                     file "M-x bongo-visualizer-build-module")
            nil)
           (t nil))))))

(defun bongo-visualizer--module-theme-capable-p ()
  "Return non-nil if the loaded C module accepts a theme argument."
  (and (fboundp 'bongo-vis-render)
       (condition-case nil
           (let ((max (cdr (func-arity #'bongo-vis-render))))
             (and (integerp max) (>= max 9)))
         (error nil))))

(defun bongo-visualizer--module-slot-capable-p ()
  "Return non-nil if the loaded C module accepts a slot argument."
  (and (fboundp 'bongo-vis-render)
       (condition-case nil
           (let ((max (cdr (func-arity #'bongo-vis-render))))
             (and (integerp max) (>= max 10)))
         (error nil))))

(defun bongo-visualizer--module-frame (player view)
  "Render one frame with the C module for PLAYER into VIEW."
  (let* ((playing (and player (not (bongo-player-paused-p player))))
         (samples
          (cond ((not playing)
                 (make-vector bongo-visualizer-window 0.0))
                ((eq bongo-visualizer-source 'demo)
                 (bongo-visualizer--demo-samples))
                (t
                 (bongo-visualizer--ensure-source player)
                 (or (bongo-visualizer--pcm-samples bongo-visualizer-window)
                     (make-vector bongo-visualizer-window 0.0))))))
    ;; Older builds of the module take only eight or nine arguments; pass
    ;; the theme and the slot only when the module knows about them.
    (let ((optional
           (cond ((and (bongo-visualizer--module-theme-capable-p)
                       (bongo-visualizer--module-slot-capable-p))
                  (list (bongo-visualizer--view-c-theme view)
                        (bongo-visualizer--view-slot view)))
                 ((bongo-visualizer--module-theme-capable-p)
                  (list (bongo-visualizer--view-c-theme view))))))
      (apply #'bongo-vis-render
             (bongo-visualizer--view-canvas view) samples
             (or (bongo-visualizer--view-width view) bongo-visualizer-width)
             (or (bongo-visualizer--view-height view)
                 bongo-visualizer-height)
             (float bongo-visualizer-sample-rate)
             (float-time)
             bongo-visualizer-style
             bongo-visualizer-transparent-background
             optional))))

(defun bongo-visualizer-render-frame (&optional view)
  "Render one visualizer frame into VIEW.
VIEW defaults to `bongo-visualizer--mode-line-view'.  Unlike
`bongo-visualizer--frame', this does not check
`bongo-visualizer-mode', so a front end such as `bongo-player-mode'
can drive its own view even when the visualizer's display is off."
  (let ((view (or view bongo-visualizer--mode-line-view)))
    (when (and view (bongo-visualizer--view-canvas view))
      ;; Notice a theme change made with `setq' and rebuild the canvas so
      ;; that the background and the Lisp gradient follow it too.
      (unless (eq bongo-visualizer-theme
                  (bongo-visualizer--view-current-theme view))
        (bongo-visualizer--setup-canvas view)
        (bongo-visualizer--refresh-view view))
      (let ((player (bongo-visualizer--player)))
        (pcase (bongo-visualizer--renderer)
          ('module (bongo-visualizer--module-frame player view))
          (_ (bongo-visualizer--frame-lisp player view)))))))

(defun bongo-visualizer--frame ()
  "Advance the animation by one frame."
  (when bongo-visualizer-mode
    (bongo-visualizer-render-frame bongo-visualizer--mode-line-view)))

(defun bongo-visualizer--renderer ()
  "Return the renderer to use: `module' or `lisp'.
When the loaded C module cannot keep separate state per canvas, two
live views would reset each other's smoothing, so fall back to the
Lisp renderer while more than one view is active."
  (pcase bongo-visualizer-renderer
    ('module 'module)
    ('lisp 'lisp)
    (_ (if (and (bongo-visualizer--module-active-p)
                (or (bongo-visualizer--module-slot-capable-p)
                    (null (cdr bongo-visualizer--views))))
           'module
         'lisp))))

(defun bongo-visualizer--frame-lisp (player view)
  "Pure-Lisp frame rendering for PLAYER into VIEW."
  (let ((active (and player
                     (not (bongo-player-paused-p player)))))
    (if active
        (progn
          (bongo-visualizer--ensure-source player)
          (setf (bongo-visualizer--view-levels view)
                (bongo-visualizer--smooth
                 (bongo-visualizer--compute-levels)
                 (bongo-visualizer--view-levels view)))
          (bongo-visualizer--track-peaks (bongo-visualizer--view-levels view)
                                         view))
      (setf (bongo-visualizer--view-levels view)
            (mapcar (lambda (level) (* level 0.9))
                    (or (bongo-visualizer--view-levels view)
                        (make-list bongo-visualizer-bands 0.0))))
      (setf (bongo-visualizer--view-peaks view)
            (mapcar (lambda (peak) (* peak 0.9))
                    (or (bongo-visualizer--view-peaks view)
                        (make-list bongo-visualizer-bands 0.0)))))
    (bongo-visualizer--render
     (or (bongo-visualizer--view-levels view)
         (make-list bongo-visualizer-bands 0.0))
     view)))

(defun bongo-visualizer--sync-source (&rest _)
  "Restart the PCM decoder for the new track, if any."
  (when (and bongo-visualizer-mode
             (eq bongo-visualizer-source 'mpv)
             bongo-player)
    (let ((file (ignore-errors (bongo-player-file-name bongo-player))))
      (when (and (stringp file)
                 (not (equal file bongo-visualizer--current-file)))
        (bongo-visualizer--start-pcm file)))))


;;;; Display

(defvar bongo-visualizer--mode-line-entry
  '(:eval (bongo-visualizer--mode-line))
  "Mode line construct that displays the visualizer canvas.")

(defun bongo-visualizer--mode-line ()
  "Return the mode line construct for the visualizer canvas."
  (let ((view bongo-visualizer--mode-line-view))
    (when (and bongo-visualizer-mode view)
      (let ((canvas (bongo-visualizer--view-canvas view)))
        (when canvas
          (propertize " " 'display canvas
                      'help-echo "Bongo visualizer"))))))

(defun bongo-visualizer--show-mode-line (show)
  "Add the visualizer to the global mode line when SHOW is non-nil."
  (if show
      (unless (member bongo-visualizer--mode-line-entry global-mode-string)
        (setq global-mode-string
              (if (listp global-mode-string)
                  (append global-mode-string
                          (list bongo-visualizer--mode-line-entry))
                (list bongo-visualizer--mode-line-entry))))
    (when (listp global-mode-string)
      (setq global-mode-string
            (delete bongo-visualizer--mode-line-entry global-mode-string)))))

(defun bongo-visualizer--setup-buffer (view)
  "Create and display the buffer showing VIEW's canvas."
  (let ((buffer (get-buffer-create bongo-visualizer-buffer-name)))
    (setf (bongo-visualizer--view-buffer view) buffer)
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (propertize " " 'display
                          (bongo-visualizer--view-canvas view)))
      (insert "\n")
      (goto-char (point-min))
      (setq-local cursor-type nil)
      (setq-local truncate-lines t)
      (setq-local mode-line-format nil)
      (setq buffer-read-only t))
    (when bongo-visualizer-side
      (display-buffer
       buffer
       `(display-buffer-in-side-window
         (side . ,bongo-visualizer-side)
         (slot . 0)
         (window-height
          . ,(1+ (ceiling
                  (/ (or (bongo-visualizer--view-height view)
                         bongo-visualizer-height)
                     (float (frame-char-height)))))))))))

;;;###autoload
(define-minor-mode bongo-visualizer-mode
  "Toggle the Bongo music visualizer.
With a prefix argument ARG, enable the mode if ARG is positive.
This is a global minor mode; the visualizer follows whichever Bongo
playlist buffer currently has an active player."
  :global t
  :group 'bongo-visualizer
  (if bongo-visualizer-mode
      (progn
        (bongo-visualizer--load-module)
        (setq bongo-visualizer--mode-line-view
              (bongo-visualizer--new-view bongo-visualizer-display))
        (bongo-visualizer--setup-canvas bongo-visualizer--mode-line-view)
        (if (eq bongo-visualizer-display 'mode-line)
            (bongo-visualizer--show-mode-line t)
          (bongo-visualizer--setup-buffer bongo-visualizer--mode-line-view))
        (add-hook 'bongo-player-started-hook #'bongo-visualizer--sync-source)
        (add-hook 'bongo-player-sought-hook #'bongo-visualizer--sync-source)
        (setq bongo-visualizer--timer
              (run-with-timer 0 (/ 1.0 (max 1 bongo-visualizer-fps))
                              #'bongo-visualizer--frame)))
    (when bongo-visualizer--timer
      (cancel-timer bongo-visualizer--timer)
      (setq bongo-visualizer--timer nil))
    (remove-hook 'bongo-player-started-hook #'bongo-visualizer--sync-source)
    (remove-hook 'bongo-player-sought-hook #'bongo-visualizer--sync-source)
    (bongo-visualizer--show-mode-line nil)
    (when bongo-visualizer--mode-line-view
      (bongo-visualizer--destroy-view bongo-visualizer--mode-line-view)
      (setq bongo-visualizer--mode-line-view nil))))


(provide 'bongo-visualizer)
;;; bongo-visualizer.el ends here
