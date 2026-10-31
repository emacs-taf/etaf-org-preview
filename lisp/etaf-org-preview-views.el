;;; etaf-org-preview-views.el --- Org document rendering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Document tree in, ETAF Views out.  Every function here is a pure function
;; of the parsed tree plus an environment plist; nothing reads a file, a
;; buffer or a frame's state behind the viewport.
;;
;; The environment carries the palette, the reading measure, the page
;; background and the callbacks the document needs: folding, link opening,
;; footnote jumps and media cards.  A color is always read through the palette,
;; so the same layout serves the face-derived appearance and the fixed ones.
;;
;; A headline is a Component.  It reads its own fold cell during render, so
;; one fold repaints one section instead of the document; children that a
;; folded parent hides are not rendered at all.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-preview-theme)

(defconst etaf-org-preview--measure-gutter 2
  "Character cells kept blank on each side of the reading measure.")

(defconst etaf-org-preview--day-names
  '(("Mon" . "周一") ("Tue" . "周二") ("Wed" . "周三") ("Thu" . "周四")
    ("Fri" . "周五") ("Sat" . "周六") ("Sun" . "周日"))
  "English day abbreviations mapped to the Chinese label the preview shows.")

;;; ---------------------------------------------------------------------------
;;; Shared helpers
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--color (env key)
  "Return ENV's palette color for semantic KEY."
  (etaf-org-preview-color key (plist-get env :palette)))

(defun etaf-org-preview--base (env)
  "Return ENV's base font size in pixels."
  (or (plist-get env :base-pixels)
      (etaf-org-preview--base-pixels)))

(defun etaf-org-preview--scaled (env factor)
  "Return ENV's base size scaled by FACTOR, rounded to an integer."
  (max 6 (round (* (etaf-org-preview--base env) factor))))

(defun etaf-org-preview--mono ()
  "Return the frame's fixed-pitch family, or nil."
  (let ((family (face-attribute 'fixed-pitch :family nil t)))
    (and (stringp family) (not (string-empty-p family)) family)))

(defun etaf-org-preview--spacer (&optional lines)
  "Return an empty spacer Box LINES lines tall."
  (etaf-node 'box (list :height (list 'lh (or lines 1))) nil))

(defun etaf-org-preview--rule (_env &optional spacing)
  "Return a hairline divider, separated from its neighbours by SPACING lines."
  (etaf-node 'etaf-divider
             (list :orientation 'horizontal
                   :margin-top (list 'lh (or spacing 0.5))
                   :margin-bottom (list 'lh (or spacing 0.5)))
             nil))

(defun etaf-org-preview--chip (env text ink background &optional bold)
  "Return a compact chip for TEXT in ENV.
INK and BACKGROUND are palette keys; BOLD picks the weight.  The chip keeps one
character cell of inline padding and a small radius, so a row of chips reads as
labels rather than as words with a fill."
  (etaf-node 'box
             (list :background-color (etaf-org-preview--color env background)
                   :color (etaf-org-preview--color env ink)
                   :border-radius '(px 3)
                   :width 'max-content
                   :flex-shrink 0
                   :padding-left '(ch 1)
                   :padding-right '(ch 1)
                   :font-size (etaf-org-preview--scaled env 0.82))
             (list (etaf-node 'text (list :font-weight (if bold 'bold 'normal))
                              (list text)))))

(defun etaf-org-preview--heading-size (env level)
  "Return the heading size in ENV for LEVEL."
  (etaf-org-preview--scaled
   env
   (pcase level
     (1 1.50)
     (2 1.34)
     (3 1.18)
     (4 1.06)
     (_ 1.00))))

(defun etaf-org-preview--heading-indent (level)
  "Return the extra left padding of a LEVEL heading, in character cells."
  (if (> level 4) (min 4 (- level 4)) 0))

(defun etaf-org-preview--heading-gap (_env level)
  "Return the space above a LEVEL heading, in body lines.
The gap separates sections without pushing a collapsed outline apart: a level
one section opens with two body lines, and each deeper level adds less."
  (list 'lh (pcase level
              (1 1.6)
              (2 1.2)
              (3 0.9)
              (4 0.6)
              (_ 0.45))))

;;; ---------------------------------------------------------------------------
;;; Inline rendering
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--timestamp-text (stamp)
  "Return STAMP formatted for reading."
  (let* ((start (plist-get stamp :start))
         (day (cdr (assoc (or (plist-get start :day) "") etaf-org-preview--day-names)))
         (hh (plist-get start :hh))
         (mm (plist-get start :mm))
         (end-hh (plist-get start :end-hh))
         (end-mm (plist-get start :end-mm))
         (time (if hh
                   (format " %02d:%02d%s" hh (or mm 0)
                           (if end-hh (format "-%02d:%02d" end-hh (or end-mm 0)) ""))
                 ""))
         (repeater (or (plist-get stamp :repeater) "")))
    (format "%04d-%02d-%02d%s%s%s"
            (plist-get start :y) (plist-get start :m) (plist-get start :d)
            (if day (concat " " day) "") time
            (if (string-empty-p repeater) "" (concat " " repeater)))))

(defun etaf-org-preview--emphasis-props (marker)
  "Return the style props of an emphasis MARKER."
  (pcase marker
    ("*" (list :font-weight 'bold))
    ("/" (list :font-style 'italic))
    ("_" (list :text-decoration-line '(underline)))
    ("+" (list :text-decoration-line '(line-through)))
    (_ nil)))

(defun etaf-org-preview--fold-ref (env id)
  "Return the fold cell of section ID through ENV."
  (funcall (plist-get env :fold-ref) id))

(defun etaf-org-preview--act (env key &rest args)
  "Call ENV's action KEY with ARGS, when the callbacks are present."
  (when-let* ((actions (plist-get env :actions)))
    (when-let* ((function (plist-get actions key)))
      (apply function args))))

(defun etaf-org-preview--link-node (target children env)
  "Return a link View for TARGET holding CHILDREN in ENV.
A text node carries one string, so a link with formatted text is a box that
holds the inline nodes and owns the activation."
  (etaf-node 'box
             (list :color (etaf-org-preview--color env :accent)
                   :text-decoration-line '(underline)
                   :on-press (lambda () (etaf-org-preview--act env :open target))
                   :role 'button
                   :tab-index 0
                   :pointer 'hand
                   :help-echo (format "%s（RET 打开）" target))
             (or children
                 (list (etaf-node 'text nil (list target))))))

(defun etaf-org-preview--inline-entries (inlines env &optional inherited)
  "Flatten INLINES into styled entries for ENV.
INHERITED is the style plist of the enclosing inline element.  An entry is
(:text STRING :props PLIST :press FUNCTION :help STRING) or (:view NODE)."
  (let (result)
    (dolist (node inlines)
      (let ((type (plist-get node :type)))
        (pcase type
          ('text
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('emphasis
           (setq result
                 (append
                  (nreverse
                   (etaf-org-preview--inline-entries
                    (plist-get node :children) env
                    (append (etaf-org-preview--emphasis-props
                             (plist-get node :marker))
                            inherited)))
                  result)))
          ('code
           (push (list :text (or (plist-get node :text) "")
                       :props (append
                               (list :background-color
                                     (etaf-org-preview--color
                                      env (if (plist-get node :verbatim)
                                              :panel2 :accent-soft))
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('link
           (let* ((target (plist-get node :target))
                  (desc (plist-get node :desc))
                  (text (if desc
                            (etaf-org-preview-inline-plain-text desc)
                          target)))
             (push (list :text text
                         :props (append
                                 (list :color (etaf-org-preview--color env :accent)
                                       :text-decoration-line '(underline))
                                 inherited)
                         :press (lambda ()
                                  (etaf-org-preview--act env :open target))
                         :help (format "%s（RET 打开）" target))
                   result)))
          ('timestamp
           (push (list :text (etaf-org-preview--timestamp-text node)
                       :props (append
                               (list :color (etaf-org-preview--color
                                             env (if (plist-get node :active)
                                                     :date :muted))
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('footnote-ref
           (let ((label (plist-get node :label)))
             (push (list :text (format "[%d]" (plist-get node :number))
                         :props (append
                                 (list :color (etaf-org-preview--color env :accent)
                                       :font-size (etaf-org-preview--scaled env 0.78))
                                 inherited)
                         :press (lambda ()
                                  (etaf-org-preview--act env :footnote label))
                         :help "跳到脚注")
                   result)))
          ('entity
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('subsup
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('statistics-cookie
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :color (etaf-org-preview--color env :muted)
                                     :font-family (etaf-org-preview--mono)
                                     :font-size (etaf-org-preview--scaled env 0.85))
                               inherited))
                 result))
          ('citation
           (push (list :text (mapconcat (lambda (key) (concat "@" key))
                                        (plist-get node :keys) " ")
                       :props (append
                               (list :color (etaf-org-preview--color env :muted)
                                     :font-family (etaf-org-preview--mono)
                                     :background-color (etaf-org-preview--color env :panel))
                               inherited))
                 result))
          ('latex-fragment
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :color (etaf-org-preview--color env :accent)
                                     :font-family (etaf-org-preview--mono)
                                     :font-style 'italic)
                               inherited))
                 result))
          ('inline-src
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :background-color
                                     (etaf-org-preview--color env :accent-soft)
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('export-snippet
           (push (list :text (or (plist-get node :text) "")
                       :props (append
                               (list :color (etaf-org-preview--color env :muted)
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('break
           (push (list :text "\n" :props inherited) result))
          ('target nil)
          (_
           (when-let* ((text (plist-get node :text)))
             (push (list :text text :props inherited) result))))))
    (nreverse result)))

(defun etaf-org-preview--merge-entries (entries)
  "Merge adjacent text ENTRIES that share their style."
  (let ((result nil))
    (dolist (entry entries)
      (let ((previous (car result)))
        (if (and previous
                 (not (plist-get previous :view))
                 (not (plist-get entry :view))
                 (null (plist-get previous :press))
                 (null (plist-get entry :press))
                 (equal (plist-get previous :props) (plist-get entry :props)))
            (setcar result (plist-put previous :text
                                      (concat (plist-get previous :text)
                                              (plist-get entry :text))))
          (push entry result))))
    (nreverse result)))

(defun etaf-org-preview--entries-nodes (entries)
  "Turn merged ENTRIES into ETAF nodes."
  (mapcar
   (lambda (entry)
     (if (plist-get entry :view)
         (plist-get entry :view)
       (etaf-node 'text
                  (append (plist-get entry :props)
                          (when (plist-get entry :press)
                            (list :on-press (plist-get entry :press)
                                  :role 'button :tab-index 0)))
                  (list (plist-get entry :text)))))
   entries))

(defun etaf-org-preview--inline-nodes (inlines env &optional inherited)
  "Return INLINES as ETAF text nodes for ENV."
  (etaf-org-preview--entries-nodes
   (etaf-org-preview--merge-entries
    (etaf-org-preview--inline-entries inlines env inherited))))

(defun etaf-org-preview--runs-box (inlines env &optional props)
  "Return a wrapping paragraph Box of INLINES in ENV with PROPS."
  (etaf-node 'box
             (append (list :width 'stretch :wrap-mode 'word)
                     props)
             (etaf-org-preview--inline-nodes inlines env)))

;;; ---------------------------------------------------------------------------
;;; Images
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--grid-for-pixels (env pixels)
  "Return (COLUMNS . ROWS) for PIXELS in ENV's reading measure.
The image keeps its aspect ratio: its natural cell size is reduced until both
dimensions fit, first the reading measure and then the row budget."
  (let* ((max-columns (max 8 (- (or (plist-get env :width) 92) 4)))
         (max-rows (or (plist-get env :image-max-rows) 24))
         (char-width (max 1 (frame-char-width)))
         (char-height (max 1 (frame-char-height))))
    (if pixels
        (let* ((width (max 1 (car pixels)))
               (height (max 1 (cdr pixels)))
               (columns (max 4 (round (/ (* 1.0 width) char-width))))
               (rows (max 1 (round (/ (* 1.0 height) char-height))))
               (scale (min 1.0 (/ (float max-columns) columns)
                           (/ (float max-rows) rows))))
          (cons (max 4 (round (* columns scale)))
                (max 1 (round (* rows scale)))))
      (cons (min 48 max-columns) 12))))

(defun etaf-org-preview--image-card (media env)
  "Return the image card for MEDIA in ENV, or a placeholder card."
  (let* ((path (plist-get media :path))
         (pixels (and (plist-get media :width)
                      (cons (plist-get media :width) (plist-get media :height))))
         (grid (etaf-org-preview--grid-for-pixels env pixels))
         (caption (plist-get media :caption)))
    (etaf-node 'column
               (list :width 'stretch :cross-align 'center :item-gap '(lh 0.5))
               (append
                (list
                 (if (and path (plist-get media :exists))
                     (etaf-node 'image
                                (list :src path
                                      :columns (car grid) :rows (cdr grid)
                                      :role 'button :tab-index 0 :pointer 'hand
                                      :on-press (lambda ()
                                                  (etaf-org-preview--act
                                                   env :open-file path))
                                      :help-echo (format "%s（RET 打开）"
                                                         (file-name-nondirectory path)))
                                nil)
                   (etaf-node 'box
                              (list :border (list '(px 1) 'solid
                                                  (etaf-org-preview--color env :border))
                                    :background-color (etaf-org-preview--color env :panel)
                                    :padding '((lh 1) (ch 2))
                                    :on-press (lambda ()
                                                (etaf-org-preview--act
                                                 env :open (or path "")))
                                    :role 'button :tab-index 0 :pointer 'hand)
                              (list (etaf-node 'text
                                               (list :color (etaf-org-preview--color
                                                             env :muted))
                                               (list (format "图片不可用：%s"
                                                             (or path "未知路径"))))))))
                (when (and caption (not (string-empty-p caption)))
                  (list (etaf-node 'text
                                   (list :color (etaf-org-preview--color env :muted)
                                         :font-size (etaf-org-preview--scaled env 0.85))
                                   (list caption))))))))

(defun etaf-org-preview--file-card (block env)
  "Return a card for a file BLOCK in ENV.
BLOCK's `:label' is what the card says; its `:path' is what activation opens."
  (let ((path (or (plist-get block :path) (plist-get block :target) ""))
        (label (or (plist-get block :label) "文件")))
    (etaf-node 'box
               (list :width 'stretch
                     :border (list '(px 1) 'solid
                                   (etaf-org-preview--color env :border))
                     :background-color (etaf-org-preview--color env :panel)
                     :padding '((lh 1) (ch 2))
                     :on-press (lambda () (etaf-org-preview--act env :open path))
                     :role 'button :tab-index 0 :pointer 'hand)
               (list (etaf-node 'text
                                (list :color (etaf-org-preview--color env :muted))
                                (list (format "%s：%s" label path)))))))

;;; ---------------------------------------------------------------------------
;;; Blocks
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--table-column-widths (floors available)
  "Return the column widths of FLOORS inside AVAILABLE cells.
A table that fits keeps its natural width, so a short table stays compact.
A wide table shrinks its columns to three cells at least and wraps the cells
that remain too long."
  (let* ((count (length floors))
         (total (apply #'+ floors)))
    (if (<= total available)
        floors
      (let* ((budget (max (* 3 count) available))
             (result (cl-loop for floor in floors
                              collect (max 3 (floor (* floor (/ (float budget)
                                                               total)))))))
        (while (> (apply #'+ result) budget)
          (let ((widest (cl-position (apply #'max result) result)))
            (setf (nth widest result) (1- (nth widest result)))))
        result))))

(cl-defun etaf-org-preview--table-row (row env widths &key header last)
  "Return one table row View of ROW in ENV.
WIDTHS holds the content width of each column.  HEADER fills the header
surface and LAST drops the closing rule."
  (let ((cells nil)
        (index 0))
    (dolist (cell (plist-get row :cells))
      (let ((width (or (nth index widths) 3)))
        (push (etaf-node 'box
                         (list :width (list 'ch (+ 2 width))
                               :flex-shrink 0
                               :padding '((lh 0) (ch 1))
                               :wrap-mode 'word
                               :text-align (or (nth index (plist-get env :table-aligns))
                                               'left))
                         (etaf-org-preview--inline-nodes
                          (plist-get cell :inlines) env
                          (when header '(:font-weight bold))))
              cells))
      (cl-incf index))
    (etaf-node 'flex
               (list :width 'stretch :align-items 'start
                     :background-color (when header
                                         (etaf-org-preview--color env :table-header))
                     :border-bottom (unless last
                                      (list '(px 1) 'solid
                                            (etaf-org-preview--color
                                             env (if header :border :rule)))))
               (nreverse cells))))

(defun etaf-org-preview--table-view (block env)
  "Return the table View of BLOCK in ENV.
Rows are flex lines of fixed-width cells, so a wide cell wraps inside its own
column and the table never grows past the reading measure."
  (let* ((rows (plist-get block :rows))
         (columns (max 1 (or (plist-get block :columns) 1)))
         (aligns (or (plist-get block :aligns) nil))
         (widths-cookie (or (plist-get block :widths) nil))
         (header-count (or (plist-get block :header-count) 0))
         (floors (cl-loop for column from 0 below columns
                          collect (or (nth column widths-cookie)
                                      (cl-loop for row in rows
                                               maximize (min 24
                                                             (string-width
                                                              (etaf-org-preview-inline-plain-text
                                                               (plist-get
                                                                (nth column (plist-get row :cells))
                                                                :inlines))))
                                               into width
                                               finally return (max 2 width)))))
         (env (plist-put env :table-aligns aligns))
         (widths (etaf-org-preview--table-column-widths
                  floors (max 8 (- (or (plist-get env :width) 92)
                                   (+ 2 (* 2 columns))))))
         (row-views nil)
         (index 0))
    (dolist (row rows)
      (push (etaf-org-preview--table-row
             row env widths
             :header (< index header-count)
             :last (= index (1- (length rows))))
            row-views)
      (cl-incf index))
    (let* ((total (+ 2 (* 2 columns) (apply #'+ widths)))
           (table (etaf-node 'column
                             (list :width 'stretch)
                             (nreverse row-views))))
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 0.5))
                 (append
                  (list (etaf-node 'box
                                   (list :width (list 'ch total)
                                         :border (list '(px 1) 'solid
                                                       (etaf-org-preview--color env :border))
                                         :border-radius '(px 4)
                                         :overflow 'hidden)
                                   (list table)))
                  (when-let* ((tblfm (plist-get block :tblfm)))
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :faint)
                                           :font-size (etaf-org-preview--scaled env 0.8))
                                     (list (format "公式未求值：%s" tblfm)))))
                  (when-let* ((caption (plist-get block :caption)))
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :muted)
                                           :font-size (etaf-org-preview--scaled env 0.85))
                                     (list caption)))))))))

(defun etaf-org-preview--list-marker (item env)
  "Return the marker View of list ITEM in ENV."
  (cond
   ((plist-get item :checkbox)
    (etaf-node 'etaf-check-mark
               (list :state (pcase (plist-get item :checkbox)
                              ('on 'done)
                              ('partial 'skipped)
                              (_ 'empty))
                     :color (if (eq (plist-get item :checkbox) 'on)
                                (etaf-org-preview--color env :ok)
                              (etaf-org-preview--color env :muted)))
               nil))
   ((plist-get item :term) nil)
   ((plist-get item :ordered)
    (etaf-node 'text
               (list :color (etaf-org-preview--color env :muted)
                     :font-family (etaf-org-preview--mono))
               (list (or (plist-get item :counter)
                         (format "%d." (or (plist-get item :number) 1))))))
   (t (etaf-node 'text
                 (list :color (etaf-org-preview--color env :muted))
                 (list "•")))))

(defun etaf-org-preview--item-views (blocks env)
  "Return BLOCKS rendered as list item content in ENV.
A nested list gets two extra cells, so each level reads as one step in."
  (let (views)
    (dolist (block blocks)
      (let ((view (etaf-org-preview--block-view block env)))
        (when view
          (when (eq (plist-get block :type) 'list)
            (setq view (etaf-node 'box
                                  (list :width 'stretch :padding-left '(ch 2))
                                  (list view))))
          (push view views))))
    (nreverse views)))

(defun etaf-org-preview--list-view (block env)
  "Return the list View of BLOCK in ENV."
  (let ((items nil))
    (dolist (item (plist-get block :items))
      (let* ((marker (etaf-org-preview--list-marker item env))
             (term (plist-get item :term))
             (content (etaf-org-preview--item-views (plist-get item :blocks) env)))
        (push
         (if term
             (etaf-node 'flex
                        (list :width 'stretch :gap '((lh 0) (ch 1))
                              :align-items 'start)
                        (list
                         (etaf-node 'box
                                    (list :width 'max-content
                                          :max-width (list 'ch 32))
                                    (etaf-org-preview--inline-nodes term env
                                                                    '(:font-weight bold)))
                         (etaf-node 'text
                                    (list :color (etaf-org-preview--color env :faint))
                                    (list "："))
                         (etaf-node 'column
                                    (list :width 'stretch :min-width '(ch 0)
                                          :item-gap '(lh 0.5))
                                    content)))
           (etaf-node 'flex
                      (list :width 'stretch :gap '((lh 0) (ch 1))
                            :align-items 'start)
                      (list
                       (etaf-node 'box
                                  (list :width '(ch 3) :flex-shrink 0)
                                  (when marker (list marker)))
                       (etaf-node 'column
                                  (list :width 'stretch :min-width '(ch 0)
                                        :item-gap '(lh 0.5))
                                  content))))
         items)))
    (etaf-node 'column
               (list :width 'stretch :item-gap '(lh 0.25))
               (nreverse items))))

(defun etaf-org-preview--code-block-view (block env &optional label)
  "Return the code card for BLOCK in ENV, labeled LABEL when given.
A block longer than the fold threshold shows its first lines and a chip to
reveal the rest."
  (let* ((text (or (plist-get block :text) ""))
         (language (or label (plist-get block :lang)))
         (body text)
         (header (when (and language (not (string-empty-p language)))
                   (etaf-node 'box
                              (list :width 'stretch
                                    :border-bottom (list '(px 1) 'solid
                                                         (etaf-org-preview--color env :border))
                                    :padding '((lh 0) (ch 2)))
                              (list (etaf-node 'text
                                               (list :color (etaf-org-preview--color env :muted)
                                                     :font-family (etaf-org-preview--mono)
                                                     :font-size (etaf-org-preview--scaled env 0.82))
                                               (list language)))))))
    (etaf-node 'box
               (list :width 'stretch
                     :background-color (etaf-org-preview--color env :panel)
                     :border (list '(px 1) 'solid
                                   (etaf-org-preview--color env :border))
                     :border-radius '(px 4))
               (append
                (when header (list header))
                (list
                 (etaf-node 'box
                            (list :width 'stretch :wrap-mode 'char
                                  :font-family (etaf-org-preview--mono)
                                  :padding (if header '((lh 0.5) (ch 2))
                                             '((lh 1) (ch 2)))
                                  :color (etaf-org-preview--color env :ink))
                            (list (etaf-node 'text nil (list body)))))))))

(defun etaf-org-preview--callout-view (block env)
  "Return the callout View of special BLOCK in ENV."
  (let* ((name (downcase (or (plist-get block :name) "")))
         (kind (pcase name
                 ((or "note" "info") (list "提示" :info :info-soft))
                 ((or "tip" "hint") (list "要点" :ok :ok-soft))
                 ((or "important" "success") (list "重要" :info :info-soft))
                 ((or "warning" "caution" "attention") (list "警告" :warn :warn-soft))
                 ((or "danger" "error") (list "危险" :danger :danger-soft))
                 (_ nil))))
    (if (null kind)
        (etaf-node 'box
                   (list :width 'stretch
                         :background-color (etaf-org-preview--color env :panel)
                         :border (list '(px 1) 'solid
                                       (etaf-org-preview--color env :border))
                         :padding '((lh 1) (ch 2)))
                   (append
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :muted)
                                           :font-size (etaf-org-preview--scaled env 0.82)
                                           :font-family (etaf-org-preview--mono))
                                     (list (upcase name))))
                    (etaf-org-preview--block-views
                     (plist-get block :blocks) env)))
      (etaf-node 'box
                 (list :width 'stretch
                       :background-color (etaf-org-preview--color env (nth 2 kind))
                       :border-left (list '(px 2) 'solid
                                          (etaf-org-preview--color env (nth 1 kind)))
                       :padding '((lh 1) (ch 2)))
                 (append
                  (list (etaf-node 'text
                                   (list :color (etaf-org-preview--color env (nth 1 kind))
                                         :font-weight 'bold)
                                   (list (nth 0 kind))))
                  (etaf-org-preview--block-views
                   (plist-get block :blocks) env))))))

(defun etaf-org-preview--quote-view (block env)
  "Return the quote View of BLOCK in ENV."
  (etaf-node 'box
             (list :width 'stretch
                   :background-color (etaf-org-preview--color env :quote-bg)
                   :border-left (list '(px 2) 'solid
                                      (etaf-org-preview--color env :quote-bar))
                   :padding '((lh 1) (ch 2)))
             (append
              (list (etaf-node 'column
                               (list :width 'stretch :item-gap '(lh 1))
                               (etaf-org-preview--block-views
                                (plist-get block :blocks) env)))
              (when-let* ((attribution (plist-get block :attribution)))
                (list (etaf-node 'box
                                 (list :width 'stretch :text-align 'right)
                                 (list (etaf-node 'text
                                                  (list :color (etaf-org-preview--color
                                                                env :muted))
                                                  (list (format "-- %s" attribution))))))))))

(defun etaf-org-preview--block-view (block env)
  "Return the View of BLOCK in ENV, or nil when nothing renders."
  (let ((type (plist-get block :type))
        (hidden (plist-get env :hidden)))
    (pcase type
      ('paragraph
       (if-let* ((media (plist-get block :media)))
           (if (eq (plist-get media :kind) 'video)
               (etaf-org-preview--file-card
                (list :path (plist-get media :path) :label "视频") env)
             (etaf-org-preview--image-card
              (plist-put media :caption (plist-get block :caption)) env))
         (etaf-org-preview--runs-box (plist-get block :inlines) env)))
      ('list (etaf-org-preview--list-view block env))
      ('table (etaf-org-preview--table-view block env))
      ('src-block (etaf-org-preview--code-block-view block env))
      ('example-block (etaf-org-preview--code-block-view block env))
      ('results (etaf-org-preview--code-block-view block env "结果"))
      ('fixed-width
       (etaf-node 'box
                  (list :width 'stretch :wrap-mode 'char
                        :font-family (etaf-org-preview--mono)
                        :color (etaf-org-preview--color env :muted))
                  (list (etaf-node 'text nil
                                   (list (or (plist-get block :text) ""))))))
      ('quote-block (etaf-org-preview--quote-view block env))
      ('special-block (etaf-org-preview--callout-view block env))
      ('center-block
       (etaf-node 'column
                  (list :width 'stretch :cross-align 'center
                        :max-width (list 'ch (round (* (or (plist-get env :width) 92)
                                                       0.8))))
                  (etaf-org-preview--block-views
                   (plist-get block :blocks) env)))
      ('verse-block
       (etaf-node 'box
                  (list :width 'stretch :wrap-mode 'word
                        :color (etaf-org-preview--color env :ink))
                  (list (etaf-node 'text nil
                                   (list (or (plist-get block :text) ""))))))
      ('comment-block
       (when hidden
         (etaf-node 'box
                    (list :width 'stretch
                          :background-color (etaf-org-preview--color env :panel)
                          :padding '((lh 1) (ch 2)))
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :faint)
                                           :font-family (etaf-org-preview--mono))
                                     (list (or (plist-get block :text) "")))))))
      ('export-block
       (etaf-org-preview--code-block-view
        block env (format "export %s" (or (plist-get block :backend) ""))))
      ('comment
       (when hidden
         (etaf-node 'text
                    (list :color (etaf-org-preview--color env :faint)
                          :font-family (etaf-org-preview--mono)
                          :font-size (etaf-org-preview--scaled env 0.85))
                    (list (or (plist-get block :text) "")))))
      ('keyword
       (when (and hidden (not (plist-get block :attached)))
         (etaf-node 'text
                    (list :color (etaf-org-preview--color env :faint)
                          :font-family (etaf-org-preview--mono)
                          :font-size (etaf-org-preview--scaled env 0.85))
                    (list (format "#+%s: %s" (plist-get block :key)
                                  (plist-get block :value))))))
      ('horizontal-rule (etaf-org-preview--rule env 0.75))
      ('display-math
       (etaf-node 'box
                  (list :width 'stretch
                        :background-color (etaf-org-preview--color env :panel)
                        :padding '((lh 1) (ch 2))
                        :text-align 'center)
                  (list (etaf-node 'text
                                   (list :color (etaf-org-preview--color env :ink)
                                         :font-family (etaf-org-preview--mono)
                                         :font-style 'italic)
                                   (list (or (plist-get block :text) ""))))))
      ('latex-environment
       (etaf-node 'box
                  (list :width 'stretch
                        :background-color (etaf-org-preview--color env :panel)
                        :border (list '(px 1) 'solid
                                      (etaf-org-preview--color env :border))
                        :padding '((lh 1) (ch 2))
                        :wrap-mode 'char)
                  (list (etaf-node 'text
                                   (list :color (etaf-org-preview--color env :muted)
                                         :font-family (etaf-org-preview--mono))
                                   (list (or (plist-get block :text) ""))))))
      ((or 'dynamic-block 'babel-call)
       (etaf-node 'box
                  (list :width 'stretch
                        :background-color (etaf-org-preview--color env :panel)
                        :border (list '(px 1) 'solid
                                      (etaf-org-preview--color env :border))
                        :padding '((lh 1) (ch 2)))
                  (append
                   (list (etaf-node 'text
                                    (list :color (etaf-org-preview--color env :muted)
                                          :font-size (etaf-org-preview--scaled env 0.82))
                                    (list (if (eq type 'dynamic-block)
                                              (format "未求值的动态块：%s"
                                                      (or (plist-get block :name) ""))
                                            (format "未执行的调用：%s"
                                                    (or (plist-get block :name) ""))))))
                   (when-let* ((text (plist-get block :text)))
                     (list (etaf-node 'text
                                      (list :color (etaf-org-preview--color env :faint)
                                            :font-family (etaf-org-preview--mono)
                                            :font-size (etaf-org-preview--scaled env 0.85))
                                      (list text)))))))
      ('include-card
       (etaf-org-preview--file-card
        (list :path (plist-get block :target)) env))
      ('footnote-def nil)
      (_ nil))))

(defun etaf-org-preview--block-views (blocks env)
  "Return the list of Views for BLOCKS in ENV.
The caller owns the spacing between blocks through its column gap."
  (let (views)
    (dolist (block blocks)
      (when-let* ((view (etaf-org-preview--block-view block env)))
        (push view views)))
    (nreverse views)))

;;; ---------------------------------------------------------------------------
;;; Headline
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--keyword-kind (todo todo-keywords)
  "Return the semantic kind of TODO from TODO-KEYWORDS."
  (when todo
    (let* ((entry (assoc todo todo-keywords))
           (state (cdr entry)))
      (cond
       ((eq state 'done)
        (if (string-match-p "CANCEL\\|ARCHIVE\\|REJECT" (upcase todo)) 'hold 'done))
       ((string-match-p "NEXT\\|STARTED\\|PROGRESS\\|DOING" (upcase todo)) 'progress)
       ((string-match-p "WAIT\\|HOLD\\|BLOCK" (upcase todo)) 'hold)
       (t 'todo)))))

(defun etaf-org-preview--keyword-chip (todo kind _env)
  "Return the keyword chip for TODO of KIND in ENV."
  (let ((variant (pcase kind
                   ('done 'success)
                   ('progress 'info)
                   ('hold 'neutral)
                   (_ 'warning))))
    (etaf-node 'etaf-tag
               (list :text todo :variant variant)
               nil)))

(defun etaf-org-preview--planning-view (planning env)
  "Return the planning line View of PLANNING in ENV.
Each field is a written label and its date, so the line stays readable
without a font that carries calendar or alarm glyphs."
  (let ((entries nil))
    (dolist (pair '((:scheduled "计划" :date)
                    (:deadline "截止" :urgent)
                    (:closed "完成" :muted)))
      (when-let* ((stamp (plist-get planning (nth 0 pair))))
        (push (etaf-node 'flex
                         (list :gap '((lh 0) (ch 1)) :align-items 'baseline)
                         (list (etaf-node 'text
                                          (list :color (etaf-org-preview--color
                                                        env (nth 2 pair))
                                                :font-size (etaf-org-preview--scaled
                                                            env 0.78)
                                                :font-weight 'bold)
                                          (list (nth 1 pair)))
                               (etaf-node 'text
                                          (list :color (etaf-org-preview--color
                                                        env (nth 2 pair))
                                                :font-size (etaf-org-preview--scaled
                                                            env 0.85)
                                                :font-family (etaf-org-preview--mono))
                                          (list (etaf-org-preview--timestamp-text
                                                 stamp)))))
              entries)))
    (when entries
      (etaf-node 'flex
                 (list :width 'stretch :gap '((lh 0) (ch 3))
                       :padding-left '(ch 2))
                 (nreverse entries)))))

(defun etaf-org-preview--properties-chip (section env hidden)
  "Return the property View of SECTION in ENV.
An expanded view (HIDDEN set) is a two-column grid; otherwise one chip."
  (let ((properties (etaf-org-preview-section-properties section)))
    (when properties
      (if hidden
          (etaf-node 'column
                     (list :width 'stretch :padding-left '(ch 2)
                           :item-gap '(lh 0.25))
                     (mapcar (lambda (pair)
                               (etaf-node 'flex
                                          (list :width 'stretch :gap '((lh 0) (ch 1)))
                                          (list
                                           (etaf-node 'text
                                                      (list :color (etaf-org-preview--color
                                                                    env :muted)
                                                            :font-family (etaf-org-preview--mono)
                                                            :font-size (etaf-org-preview--scaled
                                                                        env 0.82))
                                                      (list (car pair)))
                                           (etaf-node 'text
                                                      (list :color (etaf-org-preview--color
                                                                    env :ink)
                                                            :font-family (etaf-org-preview--mono)
                                                            :font-size (etaf-org-preview--scaled
                                                                        env 0.82))
                                                      (list (cdr pair))))))
                             properties))
        (etaf-node 'box
                   (list :padding-left '(ch 2)
                         :padding-top '(lh 0.25))
                   (list (etaf-org-preview--chip
                          env (format "属性 %d" (length properties))
                          :muted :panel)))))))

(defun etaf-org-preview--logbook-chip (section env)
  "Return the LOGBOOK summary of SECTION in ENV, or nil."
  (when-let* ((entries (etaf-org-preview-section-logbook section)))
    (let* ((minutes (cl-loop for entry in entries
                             sum (or (plist-get entry :minutes) 0)))
           (label (if (> minutes 0)
                      (format "记录 %d · %d:%02d" (length entries)
                              (/ minutes 60) (% minutes 60))
                    (format "记录 %d" (length entries)))))
      (etaf-node 'box
                 (list :padding-left '(ch 2) :padding-top '(lh 0.25))
                 (list (etaf-org-preview--chip env label :muted :panel))))))

(defun etaf-org-preview--tags-view (tags env)
  "Return TAGS as right-aligned chips in ENV."
  (when tags
    (etaf-node 'flex
               (list :flex-shrink 0 :gap '((lh 0) (ch 1)) :justify-content 'end
                     :max-width (list 'ch 32))
               (mapcar (lambda (tag)
                         (etaf-org-preview--chip
                          env (concat ":" tag ":") :muted :tag-bg))
                       tags))))

(defun etaf-org-preview--priority-box (priority env)
  "Return the priority chip of PRIORITY in ENV."
  (etaf-node 'box
             (list :border (list '(px 1) 'solid
                                 (etaf-org-preview--color
                                  env (if (equal priority "A") :danger :border)))
                   :color (etaf-org-preview--color
                           env (pcase priority
                                 ("A" :danger)
                                 ("B" :warn)
                                 (_ :muted)))
                   :font-size (etaf-org-preview--scaled env 0.78)
                   :padding-left '(ch 0.5)
                   :padding-right '(ch 0.5))
             (list (etaf-node 'text nil (list (format "#%s" priority))))))

(defun etaf-org-preview--heading-view (section state env)
  "Return the headline row of SECTION at fold STATE in ENV.
The row is the fold affordance: pressing it cycles the section."
  (let* ((level (max 1 (etaf-org-preview-section-level section)))
         (has-content (or (etaf-org-preview-section-body section)
                          (etaf-org-preview-section-children section)))
         (todo (etaf-org-preview-section-todo section))
         (kind (etaf-org-preview--keyword-kind
                todo (plist-get env :todo-keywords)))
         (priority (etaf-org-preview-section-priority section))
         (cookie (etaf-org-preview-section-cookie section))
         (tags (and (plist-get env :show-tags)
                    (etaf-org-preview-section-tags section)))
         (label (format "第%d级标题：%s%s"
                        level
                        (if todo (concat todo " ") "")
                        (etaf-org-preview-section-title-plain section)))
         (chevron (if (eq state 'folded) "chevron-right" "chevron-down"))
         (chevron-box (etaf-node 'box
                                 (list :width '(ch 2) :flex-shrink 0)
                                 (when has-content
                                   (list (etaf-node 'etaf-ui-icon
                                                    (list :name chevron
                                                          :size 0.9
                                                          :color (etaf-org-preview--color
                                                                  env :muted))
                                                    nil)))))
         (title-box (etaf-node 'box
                               (list :width 'stretch
                                     :min-width '(ch 0)
                                     :wrap-mode 'word)
                               (etaf-org-preview--inline-nodes
                                (etaf-org-preview-section-title-inlines section)
                                env
                                (list :font-size
                                      (etaf-org-preview--heading-size env level)
                                      :font-weight 'bold
                                      :color (etaf-org-preview--color env :heading)))))
         (left (append
                (list chevron-box)
                (when todo
                  (list (etaf-org-preview--keyword-chip todo kind env)))
                (when priority
                  (list (etaf-org-preview--priority-box priority env)))
                (when (etaf-org-preview-section-commented section)
                  (list (etaf-org-preview--chip env "注释" :muted :panel)))
                (when (etaf-org-preview-section-archived section)
                  (list (etaf-org-preview--chip env "归档" :muted :hold-soft)))
                (list title-box)))
         (right (append
                 (list (etaf-node 'box
                                  (list :width '(ch 1) :flex-shrink 0)
                                  nil))
                 (when cookie
                   (list (etaf-org-preview--chip env cookie :muted :panel)))
                 (when tags
                   (list (etaf-org-preview--tags-view tags env)))))
         (row (etaf-node 'flex
                         (list :width 'stretch
                               :justify-content 'space-between
                               :align-items 'center
                               :gap '((lh 0) (ch 1)))
                         (list (etaf-node 'flex
                                          (list :flex-grow 1 :flex-shrink 1
                                                :min-width '(ch 0)
                                                :align-items 'center
                                                :gap '((lh 0) (ch 1)))
                                          left)
                               (etaf-node 'flex
                                          (list :flex-shrink 0
                                                :max-width '(ch 32))
                                          right)))))
    (etaf-node 'column
               (list :width 'stretch
                     :id (concat "org-section-" (etaf-org-preview-section-id section))
                     :padding-top (etaf-org-preview--heading-gap env level)
                     :padding-left (list 'ch (etaf-org-preview--heading-indent level))
                     :on-press (lambda ()
                                 (etaf-org-preview--act
                                  env :toggle (etaf-org-preview-section-id section)))
                     :role 'button
                     :tab-index 0
                     :pointer 'hand
                     :aria-label label
                     :help-echo "按 RET 折叠或展开这一节")
               (append (list row)
                       (when (<= level 2)
                         (list (etaf-org-preview--rule env 0.3)))))))

(defun etaf-org-preview--section-body-views (section env)
  "Return the body Views of SECTION in ENV."
  (etaf-org-preview--block-views (etaf-org-preview-section-body section) env))

(etaf-define-component etaf-org-preview-section (&key section fold hidden env)
  "Render one headline SECTION with its own fold cell.
FOLD is the section's fold ref, read here so a fold repaints this section only.
HIDDEN reveals comments, properties and archives.  A parent in the `children'
state renders its children through their own cells; entering that state folds
them in one batch, so their bodies stay hidden until a reader opens one."
  :render
  (let* ((state (etaf-value fold))
         (open (eq state 'open))
         (children (and (not (eq state 'folded))
                        (etaf-org-preview-section-children section)))
         (env (etaf-current-prop :env))
         (views nil))
    (setq views (list (etaf-org-preview--heading-view section state env)))
    (when-let* ((planning (etaf-org-preview-section-planning section)))
      (when (not (eq state 'folded))
        (push (etaf-org-preview--planning-view planning env) views)))
    (when (not (eq state 'folded))
      (when-let* ((chip (etaf-org-preview--properties-chip
                         section env (etaf-value hidden))))
        (push chip views))
      (when-let* ((chip (etaf-org-preview--logbook-chip section env)))
        (push chip views)))
    (when open
      (when-let* ((body (etaf-org-preview--section-body-views section env)))
        (push (etaf-node 'column
                         (list :width 'stretch :item-gap '(lh 1)
                               :padding-top '(lh 0.5))
                         body)
              views)))
    (dolist (child children)
      (push (etaf-node 'etaf-org-preview-section
                       (list :key (etaf-org-preview-section-id child)
                             :section child
                             :fold (etaf-org-preview--fold-ref env
                                                               (etaf-org-preview-section-id child))
                             :hidden hidden
                             :env env)
                       nil)
            views))
    (etaf-node 'column
               (list :width 'stretch :item-gap '(lh 0))
               (nreverse views))))

;;; ---------------------------------------------------------------------------
;;; Document
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--hero-view (document env)
  "Return the title block of DOCUMENT in ENV.
The title, the subtitle and the byline get one line of air each, so the
opening reads as a title page instead of a stack of metadata."
  (let* ((title (or (plist-get document :title)
                    (plist-get env :fallback-title)
                    "Org 文档"))
         (subtitle (plist-get document :subtitle))
         (author (plist-get document :author))
         (date (plist-get document :date))
         (modified (plist-get env :modified))
         (keywords (plist-get document :keywords))
         (filetags (plist-get document :filetags))
         (byline (string-join (delq nil (list author date)) " · "))
         (degraded (plist-get document :degraded)))
    (etaf-node 'column
               (list :width 'stretch)
               (append
                (list
                 (etaf-node 'text
                            (list :color (etaf-org-preview--color env :heading)
                                  :font-size (etaf-org-preview--scaled env 1.65)
                                  :font-weight 'bold)
                            (list title)))
                (when (and subtitle (not (string-empty-p subtitle)))
                  (list (etaf-org-preview--spacer 1)
                        (etaf-node 'text
                                   (list :color (etaf-org-preview--color env :muted)
                                         :font-size (etaf-org-preview--scaled env 1.12))
                                   (list subtitle))))
                (when (or (not (string-empty-p byline)) modified)
                  (list (etaf-org-preview--spacer 1)
                        (etaf-node 'flex
                                   (list :width 'stretch
                                         :gap '((lh 0) (ch 1))
                                         :align-items 'center
                                         :flex-wrap 'wrap)
                                   (append
                                    (when (not (string-empty-p byline))
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint)
                                                             :font-size
                                                             (etaf-org-preview--scaled env 0.85))
                                                       (list byline))))
                                    (when (and modified
                                               (not (string-empty-p byline)))
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint))
                                                       (list "·"))))
                                    (when modified
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint)
                                                             :font-size
                                                             (etaf-org-preview--scaled env 0.78))
                                                       (list modified))))))))
                (when (or keywords filetags)
                  (list (etaf-org-preview--spacer 1)
                        (etaf-node 'flex
                                   (list :width 'stretch
                                         :gap '((lh 0.5) (ch 1))
                                         :align-items 'center
                                         :flex-wrap 'wrap)
                                   (append
                                    (mapcar (lambda (keyword)
                                              (etaf-org-preview--chip
                                               env keyword :muted :panel))
                                            keywords)
                                    (when filetags
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint)
                                                             :font-size
                                                             (etaf-org-preview--scaled env 0.82))
                                                       (list (string-join
                                                              (mapcar (lambda (tag)
                                                                        (concat "#" tag))
                                                                      filetags)
                                                              " ")))))))))
                (when (> (or degraded 0) 0)
                  (list (etaf-org-preview--spacer 0.5)
                        (etaf-org-preview--chip
                         env (format "%d 处已降级" degraded) :muted :panel)))
                (when (plist-get env :large-document)
                  (list (etaf-org-preview--spacer 0.5)
                        (etaf-node 'text
                                   (list :color (etaf-org-preview--color env :faint)
                                         :font-size (etaf-org-preview--scaled env 0.82))
                                   (list "文档较大，已按大纲展开"))))))))

(defun etaf-org-preview--toc-row (entry base env)
  "Return one table of contents row for ENTRY under BASE indentation."
  (etaf-node 'box
             (list :width 'stretch
                   :padding-left (list 'ch (* 2 (max 0 (- (nth 0 entry) base))))
                   :role 'button
                   :tab-index 0
                   :pointer 'hand
                   :help-echo "跳到这一节"
                   :on-press (lambda ()
                               (etaf-org-preview--act env :locate (nth 2 entry))))
             (list (etaf-node 'text
                              (list :color (etaf-org-preview--color env :muted)
                                    :font-size (etaf-org-preview--scaled env 0.95))
                              (list (nth 1 entry))))))

(defun etaf-org-preview--toc-view (document env)
  "Return the table of contents of DOCUMENT in ENV.
Entries indent relative to the shallowest heading the document uses, so a book
whose chapters start at level three still reads as a flat list.  The contents
sit directly on the page: a small label and quiet rows, without a card."
  (when-let* ((depth (plist-get env :toc-depth)))
    (let* ((commented (make-hash-table :test #'equal))
           (entries nil))
      (cl-labels ((walk (sections)
                    (dolist (section sections)
                      (when (etaf-org-preview-section-commented section)
                        (puthash (etaf-org-preview-section-id section)
                                 t commented))
                      (walk (etaf-org-preview-section-children section)))))
        (walk (plist-get document :sections)))
      (setq entries (cl-remove-if
                     (lambda (entry)
                       (or (> (nth 0 entry) depth)
                           (gethash (nth 2 entry) commented)))
                     (plist-get document :outline)))
      (when entries
        (let* ((base (apply #'min (mapcar (lambda (entry) (nth 0 entry)) entries)))
               (rows (mapcar (lambda (entry)
                               (etaf-org-preview--toc-row entry base env))
                             entries)))
          (etaf-node 'box
                     (list :width 'stretch
                           :border-left (list '(px 2) 'solid
                                              (etaf-org-preview--color env :rule))
                           :padding-left '(ch 2)
                           :margin-top '(lh 0.5)
                           :margin-bottom '(lh 1))
                     (list
                      (etaf-node 'text
                                 (list :color (etaf-org-preview--color env :muted)
                                       :font-size (etaf-org-preview--scaled env 0.82)
                                       :font-weight 'bold)
                                 (list "目录"))
                      (etaf-node 'box
                                 (list :width 'stretch :height '(lh 0.5)) nil)
                      (etaf-node 'column (list :width 'stretch) rows))))))))

(defun etaf-org-preview--footnotes-view (document env)
  "Return the footnote section of DOCUMENT in ENV."
  (when-let* ((footnotes (plist-get document :footnotes)))
    (etaf-node 'column
               (list :width 'stretch :item-gap '(lh 0.5)
                     :padding-top '(lh 2))
               (append
                (list (etaf-org-preview--rule env 0.75)
                      (etaf-node 'text
                                 (list :color (etaf-org-preview--color env :muted)
                                       :font-weight 'bold)
                                 (list "脚注")))
                (mapcar
                 (lambda (footnote)
                   (etaf-node 'flex
                              (list :width 'stretch :gap '((lh 0) (ch 1))
                                    :align-items 'start)
                              (list
                               (etaf-node 'box
                                          (list :width '(ch 4) :flex-shrink 0)
                                          (list (etaf-node 'text
                                                           (list :color
                                                                 (etaf-org-preview--color env :accent)
                                                                 :font-family
                                                                 (etaf-org-preview--mono))
                                                           (list (format "[%d]"
                                                                         (plist-get footnote :number))))))
                               (etaf-node 'box
                                          (list :width 'stretch :wrap-mode 'word
                                                :font-size
                                                (etaf-org-preview--scaled env 0.9))
                                          (etaf-org-preview--inline-nodes
                                           (plist-get footnote :inlines) env)))))
                 footnotes)))))

(defun etaf-org-preview--view-document (document env)
  "Return the mounted reading View of DOCUMENT in ENV.
The column is centered and capped by ENV's `:width'; a narrow window fills down
to the gutter on both sides.  Sections are Components, so a fold only repaints
the section it changes."
  (let* ((width (max 24 (or (plist-get env :width) 92)))
         (gutter etaf-org-preview--measure-gutter)
         (background (plist-get env :background))
         (sections (plist-get document :sections))
         (preamble (cl-remove-if (lambda (block)
                                   (eq (plist-get block :type) 'keyword))
                                 (plist-get document :preamble))))
    (etaf-node 'column
               (append (list :width '(vw 100) :cross-align 'center
                             :aria-label "Org 预览")
                       (when background
                         (list :background-color background)))
               (list
                (etaf-node 'column
                           (list :width 'stretch
                                 :max-width (list 'ch (+ width (* 2 gutter)))
                                 :overflow 'hidden
                                 :padding (list (list 'lh 1) (list 'ch gutter))
                                 :color (etaf-org-preview--color env :ink))
                           (append
                            (list (etaf-org-preview--hero-view document env)
                                  (etaf-org-preview--spacer 2)
                                  (etaf-org-preview--toc-view document env)
                                  (etaf-node 'column
                                             (list :width 'stretch
                                                   :item-gap '(lh 1))
                                             (etaf-org-preview--block-views
                                              preamble env)))
                            (mapcar
                             (lambda (section)
                               (etaf-node 'etaf-org-preview-section
                                          (list :key (etaf-org-preview-section-id section)
                                                :section section
                                                :fold (etaf-org-preview--fold-ref
                                                       env
                                                       (etaf-org-preview-section-id section))
                                                :hidden (plist-get env :hidden-ref)
                                                :env env)
                                          nil))
                             sections)
                            (list (etaf-org-preview--footnotes-view document env))))))))

(provide 'etaf-org-preview-views)
;;; etaf-org-preview-views.el ends here
