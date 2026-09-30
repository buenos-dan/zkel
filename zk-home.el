;;; zk-home.el --- Home tables, display state and refresh coordination -*- lexical-binding: t; -*-

;;; Commentary:
;; Home tables, display state and refresh coordination

;;; Code:
(require 'zk-commands)
(require 'button)
(require 'hl-line)
(declare-function zk-inbox-review-open "zk-inbox-review" (&optional selected))
(declare-function zk-inbox-review-edit "zk-inbox-review" ())

(defface zk-home-entry
  '((((background dark)) (:foreground "#E8E9DE" :underline nil))
    (((background light)) (:foreground "#30382E" :underline nil))
    (t (:inherit default :underline nil)))
  "Warm neutral text for clickable entries." :group 'zk)

(defface zk-home-heading '((t (:inherit zk-home-entry :weight bold)))
  "Section headings at the global text size." :group 'zk)

(defface zk-home-action
  '((((background dark)) (:foreground "#BAD69B" :underline nil))
    (((background light)) (:foreground "#4F6A30" :underline nil))
    (t (:inherit success :underline nil)))
  "Sage green for primary actions." :group 'zk)

(defface zk-home-muted
  '((((background dark)) (:foreground "#A3A89A" :underline nil))
    (((background light)) (:foreground "#616957" :underline nil))
    (t (:inherit shadow :underline nil)))
  "Secondary text and shortcuts." :group 'zk)

(defface zk-home-context
  '((((background dark)) (:foreground "#ACCAD8" :underline nil))
    (((background light)) (:foreground "#426678" :underline nil))
    (t (:inherit shadow :underline nil)))
  "Quiet blue for project and source context." :group 'zk)

(defface zk-home-overdue
  '((((background dark)) (:foreground "#E3A397"))
    (((background light)) (:foreground "#A53D30"))
    (t (:inherit warning)))
  "Past dates." :group 'zk)

(defface zk-home-rule
  '((((background dark)) (:foreground "#454B40"))
    (((background light)) (:foreground "#CED3C7"))
    (t (:inherit shadow)))
  "Subtle table separators." :group 'zk)

(defface zk-home-selection
  '((((background dark)) (:background "#323B2D" :extend t))
    (((background light)) (:background "#E5EDDD" :extend t))
    (t (:inherit hl-line)))
  "A muted green selected row." :group 'zk)

(defconst zk-home-buffer-name "*ZK*")

(defvar zk-home-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    ;; Button navigation must not shadow section and tree folding.
    (define-key map (kbd "TAB") #'zk-home-toggle-section)
    (define-key map (kbd "<tab>") #'zk-home-toggle-section)
    map))

(defcustom zk-home-item-limit 8 "Preview entries in Inbox and Notes." :type 'natnum :group 'zk)

(defun zk-home--item-limit (_section)
  zk-home-item-limit)

(defun zk-home--recent-inbox (entries)
  "Return ENTRIES newest collected first, leaving undated entries last.
Items collected in the same minute use their source position as a tie-breaker."
  (let ((dated (mapcar (lambda (entry)
                         (cons (when-let* ((date (plist-get entry :created)))
                                 (condition-case nil
                                     (float-time (org-time-string-to-time date))
                                   (error nil)))
                               entry)) entries)))
    (mapcar #'cdr
            (sort dated
                  (lambda (a b)
                    (cond ((null (car a)) nil)
                          ((null (car b)) t)
                          ((= (car a) (car b))
                           (> (or (plist-get (cdr a) :position) 0)
                              (or (plist-get (cdr b) :position) 0)))
                          (t (> (car a) (car b)))))))))

(defvar-local zk-home--timer nil)

(defvar-local zk-home--dirty nil)

(defvar-local zk-home--expanded nil)

(defvar-local zk-home--data nil)

(defvar-local zk-home--agenda-view 'day)
(defvar-local zk-home--todos-view 'daily)
(defvar-local zk-home--project-expanded nil)
(defvar-local zk-home--todos-locations nil)
(defvar-local zk-home--todos-day nil)

(defvar-local zk-home--width nil)

(defvar-local zk-home--clock-timer nil)

(defun zk-home--stop-clock ()
  (when (timerp zk-home--clock-timer)
    (cancel-timer zk-home--clock-timer))
  (setq zk-home--clock-timer nil)
  (when (timerp zk-home--timer) (cancel-timer zk-home--timer))
  (setq zk-home--timer nil))

(defun zk-home--start-clock ()
  "Refresh the native current-time marker while the dashboard is visible."
  (zk-home--stop-clock)
  (let ((buffer (current-buffer)))
    (setq zk-home--clock-timer
          (run-with-timer 60 60
                          (lambda ()
                            (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
                              (with-current-buffer buffer
                                (zk-home--queue (if (equal zk-home--todos-day (org-today))
                                                    '(agenda) '(agenda todos)))))))))
  (add-hook 'kill-buffer-hook #'zk-home--stop-clock nil t))

(defun zk-home--button (label function &optional entry face)
  (let ((start (point)))
    (insert-text-button label 'face (or face 'zk-home-entry)
                        'keymap zk-home-button-map
                        'mouse-face 'highlight 'follow-link t
                        'help-echo "RET or click to open"
                        'action (lambda (_) (funcall function)))
    (when entry (add-text-properties start (point) (list 'zk-entry entry)))))

(defun zk-home--command (label command &optional subdued)
  (let ((start (point)))
    (zk-home--button label (lambda () (call-interactively command)) nil
                     (if subdued 'zk-home-muted 'zk-home-action))
    (when (string-match "\\(\\[[^]]+\\]\\)\\'" label)
      (add-text-properties (+ start (match-beginning 1)) (+ start (match-end 1))
                           '(face zk-home-muted)))))

(defun zk-home--fit (text width &optional face)
  "Fit TEXT in WIDTH default-font columns, using FACE for measurement.
Graphical frames measure glyphs: fallback fonts need not make a Chinese
character exactly twice as wide as a Latin character.  Terminals use cells."
  (let* ((text (replace-regexp-in-string "[\n\r\t]+" " " (or text "")))
         (width (max 4 width))
         (window (or (get-buffer-window (current-buffer) t) (selected-window))))
    (if (not (display-graphic-p (window-frame window)))
        (truncate-string-to-width text width nil nil "…")
      (with-selected-window window
        (let* ((pixels (* width (window-font-width window)))
               (measure (lambda (s) (string-pixel-width
                                     (propertize s 'face (or face 'default))))))
          (if (<= (funcall measure text) pixels) text
            (let* ((glyphs (string-glyph-split text))
                   (low 0) (high (length glyphs)))
              ;; Keep grapheme clusters together when shortening a title.
              (while (< low high)
                (let* ((mid (/ (+ low high 1) 2))
                       (candidate (concat (string-join (seq-take glyphs mid) "") "…")))
                  (if (<= (funcall measure candidate) pixels)
                      (setq low mid)
                    (setq high (1- mid)))))
              (concat (string-join (seq-take glyphs low) "") "…"))))))))

(defun zk-home--align-to (column)
  "Insert a gap ending at COLUMN, independent of preceding glyph widths."
  (insert (propertize (make-string (max 1 (- column (current-column))) ?\s)
                      'face 'default
                      'display `(space :align-to (,column . width)))))

(defun zk-home--columns ()
  (max 24 (let ((windows (get-buffer-window-list (current-buffer) nil t)))
            (if windows
                (apply #'min
                       (mapcar
                        (lambda (w)
                          (floor (/ (float (window-body-width w t)) (max 1 (window-font-width w)))))
                        windows))
              (window-body-width)))))

(defun zk-home--table-columns (kind width)
  "Return field names and display widths; hide secondary columns when narrow."
  (let* ((wide (>= width 105)) (dates (>= width 62))
         (tail-width (if dates (if (eq kind 'task) 17 12) 0))
         (middle-width (if wide (min 36 (max 22 (/ width 4))) 0))
         (title-width (- width 1 (if dates (+ tail-width 3) 0)
                         (if wide (+ middle-width 3) 0))))
    (append (list (cons "TITLE" title-width))
            (when wide
              (list
               (cons (pcase kind ('task "PROJECT / AREA") ('inbox "SOURCE") (_ "TAGS")) middle-width)))
            (when dates
              (list (cons (pcase kind ('task "WHEN") ('inbox "COLLECTED") (_ "UPDATED")) tail-width))))))

(defun zk-home--date-label (stamp &optional full)
  (if (or (null stamp) (equal stamp "")) "—"
    (let ((system-time-locale "C"))
      (condition-case nil
          (format-time-string (if full "%Y-%m-%d" "%b %d") (org-time-string-to-time stamp))
        (error "See source")))))

(defun zk-home--updated (entry)
  (cond ((plist-get entry :modified) "Unsaved")
        ((null (plist-get entry :mtime)) "—")
        (t (let ((days (- (time-to-days (current-time)) (time-to-days (plist-get entry :mtime))))
                 (system-time-locale "C"))
             (cond ((= days 0) "Today") ((= days 1) "Yesterday")
                   (t (format-time-string "%Y-%m-%d" (plist-get entry :mtime))))))))

(defun zk-home--cell-values (entry kind)
  (pcase kind
    ('task
     (list (string-join (butlast (plist-get entry :path)) " / ")
           (cond
            ((plist-get entry :completed-at)
             (concat "Finished " (format-time-string "%H:%M" (org-time-string-to-time (plist-get entry :completed-at)))))
            ((plist-get entry :deadline)
             (concat "Due " (zk-home--date-label (plist-get entry :deadline))))
            ((plist-get entry :scheduled)
             (concat "Sched " (zk-home--date-label (plist-get entry :scheduled))))
            (t "Unscheduled"))))
    ('inbox (list (or (plist-get entry :origin) "Capture")
                  (zk-home--date-label (plist-get entry :created) t)))
    (_ (list (if (plist-get entry :tags) (string-join (plist-get entry :tags) ", ") "—")
             (zk-home--updated entry)))))

(defun zk-home--cell (text width &optional face)
  (let* ((face (or face 'zk-home-muted))
         (display (zk-home--fit text width face)))
    (insert (propertize display 'face face))))

(defun zk-home--table-row (entry kind columns)
  (let* ((start (point)) (title-width (cdar columns))
         (title (if (eq kind 'note)
                    (file-name-nondirectory (plist-get entry :file))
                  (plist-get entry :title)))
         (values (zk-home--cell-values entry kind))
         (prefix (if (eq kind 'task) 5 0))
         (done (and (eq kind 'task) (equal (zk-task-display-state entry) "DONE")))
         (title-face (if done 'zk-org-finished 'zk-home-entry))
         (display (zk-home--fit title (- title-width prefix) title-face)))
    (let ((button-start (point)))
      (when (eq kind 'task)
        (insert (format "%-4s " (or (zk-task-display-state entry) "TODO"))))
      (insert display)
      (make-text-button button-start (point) 'face nil 'keymap zk-home-button-map
                        'mouse-face 'highlight 'follow-link t
                        'action (lambda (_)
                                  (if (eq kind 'inbox) (zk-inbox-review-open entry) (zk-ui-open entry))))
      ;; Button properties must not erase the state and completion colors.
      (put-text-property (+ button-start prefix) (point) 'face title-face)
      (when (> prefix 0)
        (put-text-property button-start (+ button-start prefix) 'face
                           (pcase (zk-task-display-state entry)
                             ("NEXT" 'zk-org-next) ("DONE" 'zk-org-finished) (_ 'zk-org-todo)))))
    (when (= (length columns) 3)
      (zk-home--align-to (+ title-width 3))
      (zk-home--cell (car values) (cdr (nth 1 columns))
                     (cond (done 'zk-org-finished) ((eq kind 'note) 'zk-home-muted) (t 'zk-home-context))))
    (when (> (length columns) 1)
      (zk-home--align-to (+ title-width 3
                            (if (= (length columns) 3) (+ (cdr (nth 1 columns)) 3) 0)))
      (zk-home--cell (cadr values) (cdr (car (last columns)))
                     (if done 'zk-org-finished
                       (if (and (eq kind 'task) (plist-get entry :deadline)
                              (condition-case nil
                                  (< (org-time-string-to-absolute (plist-get entry :deadline))
                                     (org-today))
                                (error nil)))
                         'zk-home-overdue
                       'zk-home-muted))))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'zk-entry entry
                               'help-echo (string-join
                                           (delq nil (list title (car values)
                                                           (when (plist-get entry :scheduled)
                                                             (concat "Scheduled: "
                                                                     (plist-get entry :scheduled)))
                                                           (when (plist-get entry :deadline)
                                                             (concat "Deadline: "
                                                                     (plist-get entry :deadline)))
                                                           (plist-get entry :file)))
                                           "\n")))))

(defun zk-home--section-title (name count kind width)
  (let*
      ((label
        (pcase kind ('inbox "Create / process [i]")))
       (command
        (pcase kind ('inbox #'zk-home-inbox-new))))
    (insert (propertize (if (eq kind 'task)
                            (concat name " · " (if (eq zk-home--todos-view 'daily) "Daily" "Projects"))
                          name) 'face 'zk-home-heading)
            (propertize (format "  %d" count) 'face 'zk-home-muted))
    (when command
      (if (< (+ (current-column) (string-width label) 3) width)
          (zk-home--align-to (- width 1 (string-width label)))
        (insert "\n"))
      (zk-home--command label command))
    (insert "\n\n")))

(defun zk-home--section (name entries kind)
  "Render a table and mark its full region for TAB expansion or collapse."
  (let* ((start (point)) (width (zk-home--columns))
         (columns (zk-home--table-columns kind width)))
    (zk-home--section-title name (length entries) kind width)
    (if (null entries) (insert (propertize "Nothing here.\n" 'face 'zk-home-muted))
      (cl-loop for column in columns for n from 0
               for offset = 0 then (+ offset (cdr (nth (1- n) columns)) 3) do
               (when (> n 0) (zk-home--align-to offset))
               (zk-home--cell
                (if (= n 0) (pcase kind ('task "     TASK") ('inbox "ITEM") (_ "FILE"))
                  (car column))
                (cdr column)))
      (insert "\n" (propertize (make-string (max 1 (1- width)) ?─) 'face 'zk-home-rule) "\n")
      (dolist
          (entry (if (or (eq kind 'task) (member name zk-home--expanded)) entries (seq-take entries (zk-home--item-limit name))))
        (zk-home--table-row entry kind columns)))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'zk-section name 'zk-section-count (length entries)))))

(defun zk-home--section-start (name)
  (let ((position (point-min)) found)
    (while (and (not found) (< position (point-max)))
      (when (equal name (get-text-property position 'zk-section))
        (setq found position))
      (setq position (next-single-property-change position 'zk-section nil (point-max))))
    found))

(defun zk-home--toggle-section (&optional section)
  "Toggle the preview under point, retaining a visible entry or its header.
Agenda always shows its full selected range.
SECTION optionally names the section."
  (interactive)
  (let* ((position (if (= (point) (point-max)) (max (point-min) (1- (point))) (point)))
         (name (or section (get-text-property position 'zk-section))))
    (unless (and name (not (equal name "Agenda")))
      (user-error "Place point in Todos, Inbox or Notes to toggle"))
    (let* ((start (zk-home--section-start name))
           (count (and start (get-text-property start 'zk-section-count)))
           (entry (and (equal name (get-text-property position 'zk-section))
                       (get-text-property position 'zk-entry)))
           (column (current-column))
           (was-expanded (member name zk-home--expanded)))
      (unless start (user-error "Section is no longer visible; press g to refresh"))
      (if (<= count (zk-home--item-limit name))
          (message "All %d entries are already visible" count)
        (if was-expanded
            (setq zk-home--expanded (delete name zk-home--expanded))
          (push name zk-home--expanded))
        (zk-home--render)
        (let* ((header (zk-home--section-start name))
               (visible (and entry (text-property-any (point-min) (point-max) 'zk-entry entry))))
          (goto-char (or visible header))
          (when visible (move-to-column column))
          ;; A collapsed-away row must not leave point in another section.
          (when-let* ((window (get-buffer-window (current-buffer))))
            (when (and (not visible) was-expanded)
              (set-window-start window header))))
        (message "%s: %s" name (if was-expanded "preview" "all entries"))))))

(defun zk-home--agenda-range-label ()
  (let* ((range (zk-agenda-range zk-home--agenda-view))
         (start (calendar-gregorian-from-absolute (car range)))
         (end (calendar-gregorian-from-absolute (+ (car range) (1- (cdr range))))))
    (let ((from (format "%04d-%02d-%02d" (nth 2 start) (car start) (nth 1 start))))
      (if (eq zk-home--agenda-view 'day) from
        (format "%s — %04d-%02d-%02d" from (nth 2 end) (car end) (nth 1 end))))))

(defun zk-home-set-agenda-view (view)
  "Switch VIEW in Home's Agenda section, without opening an Agenda buffer."
  (unless (memq view '(day week)) (user-error "Choose day or week"))
  (let ((buffer (get-buffer-create zk-home-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'zk-home-mode) (zk-home-mode)))
    (unless (eq (current-buffer) buffer) (pop-to-buffer-same-window buffer))
    (with-current-buffer buffer
      ;; Generate first so a failure leaves the current selection and view intact.
      (let ((rows (zk-agenda-rows view (zk-home--columns))))
        (unless zk-home--data
          (setq zk-home--data (list :todos (zk-tasks-overview)
                                    :inbox (zk-home--recent-inbox (zk-inbox-entries)) :notes (zk-notes))))
        (setq zk-home--agenda-view view
              zk-home--data (plist-put zk-home--data :agenda rows))
        (zk-home--render)
        (goto-char (zk-home--section-start "Agenda"))
        (when-let* ((window (get-buffer-window buffer)))
          (set-window-point window (point))
          (set-window-start window (point) t))))))

(defun zk-home-agenda-day ()
  "Show today's Agenda directly in Home."
  (interactive) (zk-home-set-agenda-view 'day))
(defun zk-home-agenda-week ()
  "Show the current Monday–Sunday week directly in Home."
  (interactive) (zk-home-set-agenda-view 'week))
(defun zk-home--agenda ()
  "Insert the selected native Agenda view, preserving each row's faces."
  (let ((section-start (point)))
    (insert (propertize "Agenda" 'face 'zk-home-heading))
    (insert (propertize (format "  %s\n" (zk-home--agenda-range-label)) 'face 'zk-home-muted))
    (insert "\n")
    (unless (plist-get zk-home--data :agenda)
      (insert (propertize "No entries in this period.\n" 'face 'zk-home-muted)))
    (dolist (row (plist-get zk-home--data :agenda))
      (let* ((start (point)) (text (plist-get row :text)) (entry (plist-get row :entry)))
        (insert text)
        (when entry
          (make-text-button start (point) 'face nil 'keymap zk-home-button-map 'follow-link t
                            'help-echo "Open this agenda entry"
                            'action (lambda (_) (zk-ui-open entry)))
          ;; Button creation supplies a face; restore native per-span formatting.
          (let ((pos 0))
            (while (< pos (length text))
              (let ((next (next-property-change pos text (length text))))
                (dolist (property '(face font-lock-face display))
                  (put-text-property (+ start pos) (+ start next) property
                                     (get-text-property pos property text)))
                (setq pos next))))
          (add-text-properties start (point) (list 'zk-entry entry 'mouse-face 'highlight)))
        (insert "\n")
        (add-text-properties start (point) (list 'zk-agenda-row row))
        (when entry (put-text-property start (point) 'zk-entry entry))))
    (insert "\n")
    (put-text-property section-start (point) 'zk-section "Agenda")))

(defun zk-home--location-at (position)
  "Describe a display location by section, source identity and visual column."
  (save-excursion
    (goto-char (min position (point-max)))
    (let* ((row (get-text-property (line-beginning-position) 'zk-agenda-row))
           (entry (or (plist-get row :entry)
                      (get-text-property (point) 'zk-entry)
                      (get-text-property (line-beginning-position) 'zk-entry)))
           (marker (or (plist-get row :source-marker) (plist-get entry :source-marker)))
           (native (plist-get row :native-text))
           (section (get-text-property (line-beginning-position) 'zk-section))
           (start (or (and section (zk-home--section-start section)) (point-min))))
      (list :section section :entry entry
            :marker marker
            :position (if (and (markerp marker) (marker-buffer marker)) (marker-position marker)
                        (plist-get entry :position))
            :row-kind (when native (list (get-text-property 0 'type native)
                                         (get-text-property 0 'day native)
                                         (get-text-property 0 'time-of-day native)
                                         (get-text-property 0 'extra native)))
            :line (- (line-number-at-pos) (line-number-at-pos start))
            :column (current-column)))))

(defun zk-home--same-location-entry-p (location entry)
  "Match ENTRY to LOCATION without conflating headings in the same file."
  (let* ((old (plist-get location :entry)) (marker (plist-get location :marker))
         (position (if (and (markerp marker) (marker-buffer marker)) (marker-position marker)
                     (plist-get location :position))))
    (and old entry
         (if (plist-get old :id)
             (equal (plist-get old :id) (plist-get entry :id))
           (and (equal (plist-get old :file) (plist-get entry :file))
                (if (eq (plist-get old :record) 'note) t
                  (and position (= position (or (plist-get entry :position) -1)))))))))

(defun zk-home--find-location (location)
  "Find LOCATION after rendering, preferring the same occurrence and section."
  (let* ((section (plist-get location :section))
         (start (or (and section (zk-home--section-start section)) (point-min)))
         (end (if section (or (next-single-property-change start 'zk-section) (point-max)) (point-max)))
         found fallback)
    (save-excursion
      (goto-char start)
      (while (and (plist-get location :entry) (< (point) end) (not found))
        (let* ((row (get-text-property (point) 'zk-agenda-row))
               (entry (or (plist-get row :entry) (get-text-property (point) 'zk-entry)))
               (native (plist-get row :native-text))
               (kind (when native (list (get-text-property 0 'type native)
                                        (get-text-property 0 'day native)
                                        (get-text-property 0 'time-of-day native)
                                        (get-text-property 0 'extra native)))))
          (when (zk-home--same-location-entry-p location entry)
            (unless fallback (setq fallback (point)))
            (when (equal kind (plist-get location :row-kind)) (setq found (point)))))
        (forward-line 1))
      (goto-char (or found fallback start))
      (unless (or found fallback)
        (forward-line (max 0 (or (plist-get location :line) 0)))
        (when (>= (point) end) (goto-char (max start (1- end))) (beginning-of-line)))
      (move-to-column (or (plist-get location :column) 0))
      (point))))

(defun zk-home--agenda-command (command prefix)
  "Apply native COMMAND to the Agenda row at point, then refresh the projection."
  (let ((row (get-text-property (line-beginning-position) 'zk-agenda-row))
        (home (current-buffer)) (location (zk-home--location-at (point))) result)
    (unless (plist-get row :entry) (user-error "Place point on an Agenda entry"))
    (setq result (zk-agenda-edit-row row command prefix))
    ;; A successful source edit must stay successful even if redisplay fails.
    (condition-case err
        (with-current-buffer home
          (zk-agenda-clear-cache)
          (zk-home--update '(agenda todos))
          (setq location (plist-put location :entry result))
          (setq location (plist-put location :position (plist-get result :position)))
          (goto-char (zk-home--find-location location)))
      (error (message "Agenda updated; refresh Home with g: %s" (error-message-string err))))
    (when (plist-get result :changed) (zk-ui-report result))
    result))

(defun zk-home-agenda-todo (&optional prefix)
  "Use Org Agenda's TODO state command on the Agenda row, staying in Home."
  (interactive "P")
  (zk-home--agenda-command #'org-agenda-todo prefix))

(defun zk-home-agenda-schedule (&optional prefix)
  "Use Org Agenda's schedule command on the Agenda row."
  (interactive "P")
  (zk-home--agenda-command #'org-agenda-schedule prefix))

(defun zk-home-agenda-deadline (&optional prefix)
  "Use Org Agenda's deadline command on the Agenda row."
  (interactive "P")
  (zk-home--agenda-command #'org-agenda-deadline prefix))

(defun zk-home--render ()
  (let ((inhibit-read-only t) (system-time-locale "C")
        (location (zk-home--location-at (point)))
        (views (mapcar (lambda (window)
                         (list window (zk-home--location-at (window-start window))
                               (zk-home--location-at (window-point window))))
                       (get-buffer-window-list (current-buffer) nil t))))
    (setq zk-home--width (zk-home--columns))
    (erase-buffer)
    (insert (propertize (format-time-string "%A, %B %d, %Y") 'face 'zk-home-muted) "\n\n")
    (zk-home--agenda)
    (if (eq zk-home--todos-view 'projects)
        (zk-home--projects)
      (zk-home--section "Todos" (plist-get (plist-get zk-home--data :todos) :daily) 'task))
    (zk-home--section "Inbox" (plist-get zk-home--data :inbox) 'inbox)
    (zk-home--section "Notes" (plist-get zk-home--data :notes) 'note)
    (let ((footer (point)))
      (zk-home--command "Find note [f]" #'zk-find-note t)
      (insert "    ") (zk-home--command "Search [s]" #'zk-search t) (insert "\n")
      (add-text-properties footer (point)
                           (list 'zk-section "Notes" 'zk-section-count
                                 (length (plist-get zk-home--data :notes)))))
    (goto-char (zk-home--find-location location))
    (dolist (view views)
      (when (window-live-p (car view))
        (unless (eq (car view) (selected-window))
          (set-window-point (car view) (zk-home--find-location (nth 2 view))))
        (set-window-start (car view) (zk-home--find-location (nth 1 view)) t)))
    (set-buffer-modified-p nil)))

;;;###autoload
(defun zk-home-refresh ()
  "Explicitly refresh every section, including files changed outside Emacs."
  (interactive)
  (zk-notes-clear-cache)
  (zk-agenda-clear-cache)
  (when-let* ((buffer (get-buffer zk-home-buffer-name)))
    (with-current-buffer buffer
      (setq zk-home--dirty nil)
      (zk-home--update '(agenda todos inbox notes)))))

(defun zk-home--update (sections)
  "Update data only for SECTIONS, then render the current projection."
  (unless zk-home--data (setq sections '(agenda todos inbox notes)))
  (dolist (section sections)
    (pcase section
      ('agenda (setq zk-home--data (plist-put zk-home--data :agenda
                                              (zk-agenda-rows zk-home--agenda-view (zk-home--columns)))))
      ('todos
       (setq zk-home--data (plist-put zk-home--data :todos (zk-tasks-overview))
             zk-home--todos-day (org-today)))
      ('inbox (setq zk-home--data (plist-put zk-home--data :inbox (zk-home--recent-inbox (zk-inbox-entries)))))
      ('notes (setq zk-home--data (plist-put zk-home--data :notes (zk-notes))))))
  (zk-home--render))

(defun zk-home--queue (sections)
  "Coalesce SECTIONS until the visible home buffer can refresh."
  (setq zk-home--dirty (seq-union sections zk-home--dirty))
  (when (timerp zk-home--timer) (cancel-timer zk-home--timer))
  (let ((buffer (current-buffer)))
    (setq zk-home--timer
          (run-with-idle-timer
           0.25 nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq zk-home--timer nil)
                 (when (get-buffer-window buffer t)
                   (condition-case err
                       (progn (zk-home--update zk-home--dirty) (setq zk-home--dirty nil))
                     (error (message "ZK: %s" (error-message-string err))))))))))))

(defun zk-home-request-refresh (&optional files)
  "Refresh the sections affected by FILES; nil requests all data."
  (when-let* ((buffer (get-buffer zk-home-buffer-name)))
    (with-current-buffer buffer
      (let ((sections (unless files '(agenda todos inbox notes))))
        (dolist (file files)
          (cond ((zk-library-same-file-p file (zk-inbox-path)) (cl-pushnew 'inbox sections))
                ((zk-library-same-file-p file (zk-agenda-path))
                 (cl-pushnew 'agenda sections) (cl-pushnew 'todos sections))
                ((zk-library-file-p file) (cl-pushnew 'notes sections))))
        (when sections (zk-home--queue sections))))))

(defun zk-home--resized (_frame)
  (when-let* ((buffer (get-buffer zk-home-buffer-name)))
    (when (get-buffer-window buffer t)
      (with-current-buffer buffer
        (unless (equal zk-home--width (zk-home--columns))
          ;; Native Agenda also needs the new width for its right-aligned tags.
          (zk-home--queue '(agenda layout)))))))

(defun zk-home--window-changed (_window)
  (zk-home--queue '(agenda layout)))

(defun zk-home-start ()
  "Enable automatic home refresh integration."
  (add-hook 'zk-change-hook #'zk-home-request-refresh)
  (add-hook 'window-size-change-functions #'zk-home--resized)
  (when-let* ((buffer (get-buffer zk-home-buffer-name)))
    (with-current-buffer buffer (zk-home--start-clock))))

(defun zk-home-stop ()
  "Disable automatic home refresh and stop its timers."
  (remove-hook 'zk-change-hook #'zk-home-request-refresh)
  (remove-hook 'window-size-change-functions #'zk-home--resized)
  (when-let* ((buffer (get-buffer zk-home-buffer-name)))
    (with-current-buffer buffer
      (zk-home--stop-clock)
      (when (timerp zk-home--timer) (cancel-timer zk-home--timer))
      (setq zk-home--timer nil))))

;;;###autoload
(defun zk-home-open ()
  (interactive)
  (let ((button (or (button-at (point)) (next-button (line-beginning-position) t))))
    (if (and button (<= (button-start button) (line-end-position))) (button-activate button)
      (if-let* ((entry (get-text-property (point) 'zk-entry))) (zk-ui-open entry)
        (user-error "Select an entry or action")))))

(defvar zk-home-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (pair '(("TAB" . zk-home-toggle-section) ("<tab>" . zk-home-toggle-section)
                    ("M-n" . forward-button) ("M-p" . backward-button)
                    ("<backtab>" . backward-button) ("RET" . zk-home-open)
                    ("i" . zk-home-insert)
                    ("a" . zk-open-agenda) ("t" . zk-home-todo) ("d" . zk-home-agenda-day) ("w" . zk-home-agenda-week)
                    ("y" . zk-year) ("<escape>" . zk-home-todos-daily)
                    ("C-c C-s" . zk-home-agenda-schedule) ("C-c C-d" . zk-home-agenda-deadline)
                    ("x" . zk-item-menu) ("n" . next-line) ("p" . previous-line) ("f" . zk-find-note)
                    ("s" . zk-search) ("g" . zk-home-refresh) ("?" . zk-menu)))
      (define-key map (kbd (car pair)) (cdr pair)))
    map))

;;;###autoload
(define-derived-mode zk-home-mode special-mode
  "ZK"
  (setq-local header-line-format nil left-fringe-width 0 right-fringe-width 0
              left-margin-width 2 right-margin-width 2 truncate-lines t
              mode-line-format '("  ZK    RET Open    g Refresh"))
  (setq-local hl-line-face 'zk-home-selection)
  (hl-line-mode 1)
  (zk-home--start-clock)
  (add-hook 'window-buffer-change-functions #'zk-home--window-changed nil t))

;;;###autoload
(defun zk-home ()
  (interactive)
  (let ((buffer (get-buffer-create zk-home-buffer-name)))
    (with-current-buffer buffer (unless (derived-mode-p 'zk-home-mode) (zk-home-mode)))
    (pop-to-buffer-same-window buffer) (zk-home-refresh) buffer))

(defun zk-home--project-node (key &optional nodes)
  "Find a project tree node by KEY."
  (seq-some (lambda (node)
              (if (equal key (zk-task-tree-key node)) node
                (zk-home--project-node key (plist-get node :children))))
            nodes))

(defun zk-home--project-row (node depth ancestors)
  (let* ((entry (plist-get node :entry)) (children (plist-get node :children))
         (key (zk-task-tree-key node)) (expanded (member key zk-home--project-expanded))
         (state (plist-get entry :state)) (start (point))
         (prefix (concat (make-string (* depth 2) ?\s)
                         (if children (if expanded "▾ " "▸ ") "  ")))
         (status (if (member state '("TODO" "NEXT")) (concat state " ") ""))
         (counts (if children (format "  %d TODO · %d NEXT" (plist-get node :todo) (plist-get node :next)) ""))
         (width (max 12 (- (zk-home--columns) (string-width prefix) (string-width status) (string-width counts))))
         (title (zk-home--fit (plist-get entry :title) width 'zk-home-entry)))
    (insert prefix)
    (when (not (string-empty-p status))
      (insert (propertize status 'face (if (equal state "NEXT") 'zk-org-next 'zk-org-todo))))
    (zk-home--button title (lambda () (zk-ui-open entry)) entry)
    (insert (propertize counts 'face 'zk-home-muted) "\n")
    (add-text-properties start (point)
                         (list 'zk-entry entry 'zk-project-node node 'zk-project-ancestors ancestors))
    (when (and children expanded)
      (dolist (child children) (zk-home--project-row child (1+ depth) (append ancestors (list key)))))))

(defun zk-home--projects ()
  (let* ((start (point)) (nodes (plist-get (plist-get zk-home--data :todos) :projects))
         (count (apply #'+ (mapcar (lambda (node) (+ (plist-get node :todo) (plist-get node :next))) nodes))))
    (zk-home--section-title "Todos" count 'task (zk-home--columns))
    (if nodes (dolist (node nodes) (zk-home--project-row node 0 nil))
      (insert (propertize "No TODO or NEXT tasks.\n" 'face 'zk-home-muted)))
    (insert "\n")
    (put-text-property start (point) 'zk-section "Todos")))

(defun zk-home-toggle-section (&optional section)
  "Fold a project node or expand Inbox/Notes; Daily Todos shows every row."
  (interactive)
  (let ((section (or section (get-text-property (line-beginning-position) 'zk-section))))
    (if (not (equal section "Todos")) (zk-home--toggle-section section)
      (if (not (eq zk-home--todos-view 'projects))
          (message "All NEXT and today's DONE tasks are visible")
        (let* ((node (get-text-property (line-beginning-position) 'zk-project-node))
               (key (if (plist-get node :children) (zk-task-tree-key node)
                      (car (last (get-text-property (line-beginning-position) 'zk-project-ancestors)))))
               (roots (plist-get (plist-get zk-home--data :todos) :projects)))
          (unless key (user-error "Place point on a project or one of its tasks"))
          (setq node (zk-home--project-node key roots))
          (if (member key zk-home--project-expanded)
              (setq zk-home--project-expanded (delete key zk-home--project-expanded))
            (push key zk-home--project-expanded))
          (let ((location (list :section "Todos" :entry (plist-get node :entry)
                                :marker (plist-get (plist-get node :entry) :source-marker) :column 0)))
            (zk-home--render)
            (goto-char (zk-home--find-location location))))))))

(defun zk-home-todos-projects ()
  "Browse the Agenda task hierarchy in the Home Todos section."
  (interactive)
  (let ((buffer (get-buffer-create zk-home-buffer-name)))
    (unless (eq buffer (current-buffer)) (pop-to-buffer-same-window buffer))
    (unless (derived-mode-p 'zk-home-mode) (zk-home-mode))
    (unless zk-home--data (zk-home-refresh))
    (unless (eq zk-home--todos-view 'projects)
      (setf (alist-get 'daily zk-home--todos-locations) (zk-home--location-at (point)))
      ;; Read latest tasks before choosing, including edits made outside Home.
      (setq zk-home--data (plist-put zk-home--data :todos (zk-tasks-overview)))
      (setq zk-home--todos-view 'projects)
      (let* ((previous (alist-get 'projects zk-home--todos-locations))
             (daily (alist-get 'daily zk-home--todos-locations))
             (location (or previous (and (equal (plist-get daily :section) "Todos") daily)))
             (entry (plist-get location :entry)))
        (when (and entry (not previous))
          (setq zk-home--project-expanded
                (seq-union zk-home--project-expanded (plist-get entry :ancestor-keys) #'equal)))
        (zk-home--render)
        (goto-char (if location (zk-home--find-location location) (zk-home--section-start "Todos")))))))

(defun zk-home-todos-daily ()
  "Leave project selection and restore the daily task table."
  (interactive)
  (when (eq zk-home--todos-view 'projects)
    (let* ((current (zk-home--location-at (point)))
           (daily (alist-get 'daily zk-home--todos-locations))
           (daily-entries (plist-get (plist-get zk-home--data :todos) :daily))
           (location (if (and (equal (plist-get current :section) "Todos")
                              (seq-some (lambda (e) (zk-home--same-location-entry-p current e)) daily-entries))
                         current daily)))
      (setf (alist-get 'projects zk-home--todos-locations) current)
      (setq zk-home--todos-view 'daily)
      (zk-home--render)
      (goto-char (if (and location (equal (plist-get location :section) "Todos"))
                     (zk-home--find-location location) (zk-home--section-start "Todos"))))))

(defun zk-home-inbox-new ()
  "Open the Inbox new-item draft and enter editing."
  (interactive)
  (zk-inbox-review-open)
  (zk-inbox-review-edit))

(defun zk-home-insert ()
  "Insert into the current section: select NEXT tasks or capture an Inbox item."
  (interactive)
  (pcase (get-text-property (line-beginning-position) 'zk-section)
    ("Todos" (zk-home-todos-projects))
    ("Inbox" (zk-home-inbox-new))
    (_ (user-error "Place point in Todos or Inbox to insert"))))

(defun zk-home-todo (&optional prefix)
  "Use native Org state selection in Agenda or Todos without leaving Home."
  (interactive "P")
  (if (not (equal (get-text-property (line-beginning-position) 'zk-section) "Todos"))
      (zk-home-agenda-todo prefix)
    (let* ((location (zk-home--location-at (point))) (entry (plist-get location :entry)) result)
      (unless (member (plist-get entry :state) (zk-org-states))
        (user-error "Select a TODO, NEXT or DONE task"))
      (setq result (zk-org-edit-todo entry prefix))
      ;; Match by identity, never by stale buffer offsets after the update.
      (setq location (plist-put location :entry result))
      (setq location (plist-put location :position (plist-get result :position)))
      (condition-case err
          (progn (zk-agenda-clear-cache) (zk-home--update '(agenda todos))
                 (goto-char (zk-home--find-location location)))
        (error (message "Task updated; refresh Home with g: %s" (error-message-string err))))
      (zk-ui-report result)
      result)))

(provide 'zk-home)
;;; zk-home.el ends here
