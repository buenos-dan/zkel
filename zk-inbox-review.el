;;; zk-inbox-review.el --- Unified Inbox editor and organizer -*- lexical-binding: t; -*-
;;; Commentary:
;; The Org editor owns drafts; the two read-only panels project that state.
;;; Code:
(require 'zk-inbox)
(require 'zk-ui)
(require 'button)

(defconst zk-inbox-review-buffer-name "*ZK Inbox*")
(defconst zk-inbox-review--queue-name "*ZK Inbox Queue*")
(defconst zk-inbox-review--controls-name "*ZK Inbox Actions*")
(defface zk-inbox-review-heading '((t (:inherit default :weight bold))) "Headings." :group 'zk)
(defface zk-inbox-review-action
  '((((background dark)) (:foreground "#BAD69B" :underline nil))
    (((background light)) (:foreground "#4F6A30" :underline nil)))
  "Actions." :group 'zk)
(defface zk-inbox-review-muted '((t (:inherit shadow :underline nil))) "Details." :group 'zk)

(defvar-local zk-inbox-review--entries nil)
(defvar-local zk-inbox-review--drafts nil)
(defvar-local zk-inbox-review--selected 'new)
(defvar-local zk-inbox-review--last-destination nil)
(defvar-local zk-inbox-review--last-result nil)
(defvar-local zk-inbox-review--notice nil)
(defvar-local zk-inbox-review--error nil)
(defvar-local zk-inbox-review--error-field nil)
(defvar-local zk-inbox-review--filter "")
(defvar-local zk-inbox-review--configuration nil)
(defvar-local zk-inbox-review--origin nil)
(defvar-local zk-inbox-review--loading nil)
(defvar-local zk-inbox-review--editing nil)
(defvar-local zk-inbox-review--layout-busy nil)
(defvar-local zk-inbox-review--resize-timer nil)

(defmacro zk-inbox-review--with-editor (&rest body)
  (declare (indent 0) (debug t))
  `(with-current-buffer (or (get-buffer zk-inbox-review-buffer-name)
                            (user-error "Open Inbox with i first"))
     ,@body))

(defun zk-inbox-review--entry ()
  (seq-find (lambda (entry) (equal (plist-get entry :ui-key) zk-inbox-review--selected))
            zk-inbox-review--entries))

(defun zk-inbox-review--same (entry old)
  (if (plist-get entry :id) (equal (plist-get entry :id) (plist-get old :id))
    (let ((marker (plist-get old :ui-marker)))
      (and (markerp marker) (marker-buffer marker)
           (equal (plist-get entry :file) (buffer-file-name (marker-buffer marker)))
           (= (plist-get entry :position) (marker-position marker))))))

(defun zk-inbox-review--inventory ()
  (setq zk-inbox-review--entries
        (mapcar (lambda (entry)
                  (let ((old (seq-find (lambda (old) (zk-inbox-review--same entry old))
                                       zk-inbox-review--entries)))
                    (append entry (list :ui-key (or (plist-get old :ui-key) (plist-get entry :id)
                                                    (gensym "inbox-"))
                                        :ui-marker (zk-org-locate entry)))))
                (zk-inbox-entries))))

(defun zk-inbox-review--draft ()
  (or (gethash zk-inbox-review--selected zk-inbox-review--drafts)
      (let* ((entry (zk-inbox-review--entry))
             (draft (list :source entry :text (if entry (zk-inbox-edit-text entry) "")
                          :target 'inbox :kind 'task :state "TODO" :point 1)))
        (puthash zk-inbox-review--selected draft zk-inbox-review--drafts) draft)))

(defun zk-inbox-review--dirty-p ()
  (let (dirty)
    (maphash (lambda (_ draft) (when (plist-get draft :dirty) (setq dirty t)))
             zk-inbox-review--drafts)
    dirty))

(defun zk-inbox-review--remember ()
  (unless zk-inbox-review--loading
    (let ((draft (zk-inbox-review--draft)))
      (setq draft (plist-put draft :text (buffer-substring-no-properties (point-min) (point-max))))
      (puthash zk-inbox-review--selected (plist-put draft :point (point)) zk-inbox-review--drafts))))

(defun zk-inbox-review--changed (&rest _)
  (unless zk-inbox-review--loading
    (zk-inbox-review--remember)
    (puthash zk-inbox-review--selected (plist-put (zk-inbox-review--draft) :dirty t)
             zk-inbox-review--drafts)
    (setq zk-inbox-review--error nil)
    (zk-inbox-review--render)))

(defun zk-inbox-review--set (key value)
  (zk-inbox-review--with-editor
   (zk-inbox-review--remember)
   (let ((draft (plist-put (zk-inbox-review--draft) key value)))
     (puthash zk-inbox-review--selected (plist-put draft :dirty t) zk-inbox-review--drafts))
   (setq zk-inbox-review--error nil zk-inbox-review--error-field nil)
   (set-buffer-modified-p t)
   (zk-inbox-review--render) (zk-inbox-review--layout)))

(defun zk-inbox-review--focus ()
  (when-let* ((window (get-buffer-window zk-inbox-review-buffer-name))) (select-window window)))

(defun zk-inbox-review--select (key)
  (zk-inbox-review--with-editor
   (zk-inbox-review--remember)
   (setq zk-inbox-review--selected key zk-inbox-review--error nil zk-inbox-review--error-field nil)
   (let* ((draft (zk-inbox-review--draft)) (zk-inbox-review--loading t)
          (inhibit-read-only t))
     (erase-buffer) (insert (plist-get draft :text))
     (goto-char (min (point-max) (or (plist-get draft :point) 1)))
     (setq buffer-undo-list nil)
     (set-buffer-modified-p (zk-inbox-review--dirty-p)))
   (zk-inbox-review--set-editing nil)
   (zk-inbox-review--render) (zk-inbox-review--layout))
  (zk-inbox-review--focus))

(defun zk-inbox-review-new ()
  "Return to the new-item draft without losing edits elsewhere."
  (interactive) (zk-inbox-review--select 'new))

(defun zk-inbox-review--button (label function &optional face)
  (insert-text-button label 'face (or face 'zk-inbox-review-action)
                      'mouse-face 'highlight 'follow-link t
                      'action (lambda (_) (funcall function))))

(defun zk-inbox-review--destination-label (destination)
  (cond ((plist-get destination :new-project)
         (format "%s / %s (new)" (or (plist-get destination :new-area)
                                     (string-join (plist-get (plist-get destination :parent) :path)
                                                  " / "))
                 (plist-get destination :new-project)))
        ((plist-get destination :new-area) (concat (plist-get destination :new-area) " (new)"))
        (destination (string-join (plist-get destination :path) " / "))
        (t "Choose area / project")))

(defun zk-inbox-review--action-label (draft)
  (pcase (plist-get draft :target)
    ('inbox (if (plist-get draft :source) "Save changes" "Save to Inbox"))
    ('agenda (if (plist-get draft :source) "Move to Agenda" "Save to Agenda"))
    ('archive "Archive item")))

(defun zk-inbox-review--field (name key value command error-field)
  (insert (propertize (format "%-14s" name) 'face 'zk-inbox-review-muted))
  (zk-inbox-review--button value command (if (eq key error-field) 'error 'zk-inbox-review-action))
  (insert "\n"))

(defun zk-inbox-review--render-controls ()
  (let* ((draft (zk-inbox-review--draft)) (target (plist-get draft :target))
         (kind (plist-get draft :kind)) (source (plist-get draft :source))
         (error-field zk-inbox-review--error-field) (error-message zk-inbox-review--error)
         (notice zk-inbox-review--notice) (suggestion zk-inbox-review--last-destination)
         (result zk-inbox-review--last-result) (editing zk-inbox-review--editing)
         (count (length zk-inbox-review--entries)))
    (with-current-buffer (get-buffer-create zk-inbox-review--controls-name)
      (unless (derived-mode-p 'zk-inbox-review-panel-mode) (zk-inbox-review-panel-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (if source "Inbox item" "New item") 'face 'zk-inbox-review-heading)
                (propertize
                 (format "  ·  %d pending%s\n" count (if (plist-get draft :dirty) "  ·  Draft" ""))
                 'face 'zk-inbox-review-muted))
        (zk-inbox-review--button "+ New [c]" #'zk-inbox-review-new)
        (insert "   ") (zk-inbox-review--button "Items [j]" #'zk-inbox-review-jump)
        (insert "   ")
        (if editing
            (zk-inbox-review--button "Finish editing [C-c C-c / ESC]" #'zk-inbox-review-finish-edit)
          (zk-inbox-review--button "Edit [e]" #'zk-inbox-review-edit))
        (insert "   ") (zk-inbox-review--button "Back [q]" #'zk-inbox-review-quit)
        (insert "\n\n")
        (dolist (choice '((inbox "Inbox" zk-inbox-review-keep "i")
                          (agenda "Agenda" zk-inbox-review-plan "p")))
          (zk-inbox-review--button
           (concat (if (eq target (car choice)) (concat "[" (cadr choice) "]") (cadr choice))
                   " [" (nth 3 choice) "]")
           (nth 2 choice)
           (if (eq target (car choice)) 'zk-inbox-review-action
             'zk-inbox-review-muted))
          (insert "   "))
        (when source
          (zk-inbox-review--button "Archive [a]"
                                   #'zk-inbox-review-archive 'zk-inbox-review-muted))
        (insert "\n")
        (when (eq target 'agenda)
           (zk-inbox-review--field "Type [t]" :kind (capitalize (symbol-name kind))
                                   #'zk-inbox-review-type error-field)
           (zk-inbox-review--field "Location [d]" :destination
                                   (zk-inbox-review--destination-label (plist-get draft :destination))
                                   #'zk-inbox-review-destination error-field)
           (when (and suggestion (not (plist-get draft :destination)))
             (insert (propertize "Suggested " 'face 'zk-inbox-review-muted))
             (zk-inbox-review--button (zk-inbox-review--destination-label suggestion)
                                      (lambda () (zk-inbox-review--set :destination suggestion)))
             (insert "\n"))
           (when (eq kind 'task)
             (zk-inbox-review--field "State [w]" :state (plist-get draft :state) #'zk-inbox-review-state
                                     error-field))
           (unless (eq kind 'project)
             (dolist (spec '(("Scheduled [s]" :scheduled zk-inbox-review-schedule)
                             ("Deadline [l]" :deadline zk-inbox-review-deadline)))
               (let*
                   ((key (nth 1 spec)) (value (plist-get draft key))
                    (original (plist-get source key)))
                 (insert (propertize (format "%-14s" (car spec)) 'face 'zk-inbox-review-muted))
                 (zk-inbox-review--button
                  (cond ((equal value "") "None") (value value)
                        (original (concat original " (kept)"))
                        ((and (eq key :scheduled) (eq kind 'event)) "Choose date / time (required)")
                        (t "Optional"))
                  (nth 2 spec) (if (eq key error-field) 'error 'zk-inbox-review-action))
                 (when (or value original)
                   (insert "  ")
                   (zk-inbox-review--button (if (eq key :scheduled) "Clear [S]" "Clear [L]")
                                            (lambda () (zk-inbox-review--set key ""))
                                            'zk-inbox-review-muted))
                 (insert "\n")))))
        (when notice (insert (propertize notice 'face 'zk-inbox-review-muted) "\n"))
        (when error-message (insert (propertize error-message 'face 'error) "\n"))
        (insert "\n")
        (zk-inbox-review--button (concat (zk-inbox-review--action-label draft)
                                         (if editing " [C-x C-s]" " [RET]"))
                                 #'zk-inbox-review-apply)
        (when source
          (insert "   ")
          (zk-inbox-review--button "Source [o]" #'zk-inbox-review-open-source
                                   'zk-inbox-review-muted))
        (when result
          (insert "   ")
          (zk-inbox-review--button "Last result [v]" #'zk-inbox-review-open-result
                                   'zk-inbox-review-muted))
        (insert
         (propertize (if editing
                         "\nEDITING — First line = summary. C-c C-c or ESC finishes editing; RET inserts a newline.\n"
                       "\nBROWSE — e Edit · RET Save · [ / ] Previous / next item\n")
                     'face 'zk-inbox-review-muted))
        (goto-char (point-min)) (set-buffer-modified-p nil)))))

(defun zk-inbox-review--render-queue ()
  (let ((entries zk-inbox-review--entries) (drafts zk-inbox-review--drafts)
        (selected zk-inbox-review--selected) (filter zk-inbox-review--filter))
    (with-current-buffer (get-buffer-create zk-inbox-review--queue-name)
      (unless (derived-mode-p 'zk-inbox-review-queue-mode) (zk-inbox-review-queue-mode))
      (let ((inhibit-read-only t) (case-fold-search t) selected-point)
        (erase-buffer)
        (insert
         (propertize (format "Inbox  %d\n\n" (length entries)) 'face 'zk-inbox-review-heading))
        (zk-inbox-review--button "+ New item" #'zk-inbox-review-new)
        (when (plist-get (gethash 'new drafts) :dirty) (insert "  *"))
        (insert "\n\n")
        (zk-inbox-review--button
         (if (string-empty-p filter) "Search [/]" (concat "Search: " filter))
         #'zk-inbox-review-search 'zk-inbox-review-muted)
        (insert "\n\n")
        (dolist (entry entries)
          (let* ((key (plist-get entry :ui-key)) (draft (gethash key drafts))
                 (title
                  (if draft (car (split-string (plist-get draft :text) "\n"))
                    (plist-get entry :title)))
                 (start (point)))
            (when (string-match-p (regexp-quote filter) title)
              (when (equal key selected) (setq selected-point start))
              (zk-inbox-review--button
               (concat (if (equal key selected) "> " "  ") title
                       (if (plist-get draft :dirty) " *" ""))
               (lambda () (zk-inbox-review--select key))
               (if (equal key selected) 'zk-inbox-review-action 'default))
              (insert "\n"
                      (propertize (concat "  " (or (plist-get entry :created) "Unprocessed")) 'face
                                  'zk-inbox-review-muted)
                      "\n\n")
              (put-text-property start (point) 'zk-inbox-key key))))
        (when (null entries)
          (insert
           (propertize "Inbox is clear.\nCapture something new.\n" 'face 'zk-inbox-review-muted)))
        (goto-char (or selected-point (point-min))) (set-buffer-modified-p nil)))))

(defun zk-inbox-review--render ()
  (zk-inbox-review--render-controls) (zk-inbox-review--render-queue))

(defun zk-inbox-review--layout ()
  "Place settings above the editor, and the queue to the left when space permits."
  (unless zk-inbox-review--layout-busy
    (let ((zk-inbox-review--layout-busy t))
      (when-let* ((editor (get-buffer-window (current-buffer))))
        (save-selected-window
          (let* ((queue (get-buffer-window zk-inbox-review--queue-name))
                 (controls (get-buffer-window zk-inbox-review--controls-name))
                 (width (+ (window-total-width editor) (if queue (window-total-width queue) 0)))
                 (wide (>= width 105)) (window-min-height 3) (window-min-width 20)
                 (window-combination-limit t))
            (when (and queue (not wide)) (delete-window queue) (setq queue nil))
            (unless controls
              (setq controls
                    (split-window editor (- (max 3 (min 9 (/ (window-total-height editor) 3))))
                                  'above))
              (set-window-buffer controls zk-inbox-review--controls-name)
              (set-window-parameter controls 'no-other-window t))
            (when (and wide (not queue))
              (setq queue
                    (split-window (window-parent editor) (- (max 27 (floor (* width 0.3)))) 'left))
              (set-window-buffer queue zk-inbox-review--queue-name))
            (let*
                ((lines
                  (with-current-buffer zk-inbox-review--controls-name
                    (count-lines (point-min) (point-max))))
                 (available (+ (window-total-height controls) (window-total-height editor)))
                 (desired (max 3 (min (+ lines 1) (- available (if (>= available 14) 7 3))))))
              (unless (= desired (window-total-height controls))
                (window-resize controls (- desired (window-total-height controls)))))))))))

(defun zk-inbox-review--resized (_frame)
  (when-let* ((buffer (get-buffer zk-inbox-review-buffer-name)))
    (with-current-buffer buffer
      (when (and (not zk-inbox-review--layout-busy) (get-buffer-window buffer))
        (when (timerp zk-inbox-review--resize-timer) (cancel-timer zk-inbox-review--resize-timer))
        (setq zk-inbox-review--resize-timer
              (run-with-idle-timer 0.1 nil
                                   (lambda () (when (buffer-live-p buffer)
                                                (with-current-buffer buffer
                                                  (condition-case nil (zk-inbox-review--layout)
                                                    (error nil)))))))))))

(defun zk-inbox-review-keep () (interactive) (zk-inbox-review--set :target 'inbox))
(defun zk-inbox-review-plan () (interactive) (zk-inbox-review--set :target 'agenda))
(defun zk-inbox-review-archive ()
  "Archive the current Inbox item immediately, including its edited text."
  (interactive)
  (zk-inbox-review--with-editor
   (unless (plist-get (zk-inbox-review--draft) :source)
     (user-error "Select an existing Inbox item to archive"))
   (zk-inbox-review-apply 'archive)))
(defun zk-inbox-review-type ()
  (interactive)
  (zk-inbox-review--set :kind
                        (intern
                         (downcase (completing-read "Type: " '("Task" "Event" "Project") nil t)))))
(defun zk-inbox-review-state ()
  (interactive)
  (zk-inbox-review--set :state (completing-read "State: " (zk-org-states 'active) nil t)))

(defun zk-inbox-review-destination ()
  (interactive)
  (let* ((entries (zk-projects))
         (choices (cl-loop for entry in entries for n from 1
                           collect
                           (cons (format "%s [%d]" (string-join (plist-get entry :path) " / ") n)
                                 entry)))
         (selected
          (completing-read "Location: " (append choices '("+ New area" "+ New project")) nil t)))
    (zk-inbox-review--set :destination
                          (cond
                           ((equal selected "+ New area")
                            (list :new-area (zk-library-validate-title (read-string "New area: "))))
                           ((equal selected "+ New project")
                            (let ((title (zk-library-validate-title (read-string "New project: ")))
                                  (areas
                                   (seq-filter (lambda (entry) (= 1 (length (plist-get entry :path)))) entries)))
                              (if areas (list :new-project title :parent (zk-ui-choose "Area: " areas))
                                (list :new-project title :new-area
                                      (zk-library-validate-title (read-string "New area: "))))))
                           (t (cdr (assoc selected choices)))))))

(defun zk-inbox-review-schedule ()
  (interactive) (zk-inbox-review--set :scheduled (zk-ui-read-date "Scheduled")))
(defun zk-inbox-review-deadline ()
  (interactive) (zk-inbox-review--set :deadline (zk-ui-read-date "Deadline")))
(defun zk-inbox-review--step (offset)
  (zk-inbox-review--with-editor
   (let* ((keys (mapcar (lambda (entry) (plist-get entry :ui-key)) zk-inbox-review--entries))
          (index (cl-position zk-inbox-review--selected keys :test #'equal))
          (next (if index (+ index offset) (if (> offset 0) 0 (1- (length keys))))))
     (if (and (>= next 0) (< next (length keys))) (zk-inbox-review--select (nth next keys))
       (message "No more Inbox items in this direction")))))
(defun zk-inbox-review-next () (interactive) (zk-inbox-review--step 1))
(defun zk-inbox-review-previous () (interactive) (zk-inbox-review--step -1))
(defun zk-inbox-review-jump ()
  (interactive)
  (zk-inbox-review--with-editor
   (let* ((choices (cons '("+ New item" . new)
                         (cl-loop for entry in zk-inbox-review--entries for n from 1
                                  collect
                                  (cons (format "%s [%d]" (plist-get entry :title) n)
                                        (plist-get entry :ui-key)))))
          (choice (completing-read "Inbox item: " choices nil t)))
     (zk-inbox-review--select (cdr (assoc choice choices))))))
(defun zk-inbox-review-search ()
  (interactive)
  (zk-inbox-review--with-editor
   (setq zk-inbox-review--filter (read-string "Filter Inbox: " zk-inbox-review--filter))
   (zk-inbox-review--render-queue)))

(defun zk-inbox-review-reload ()
  "Reload the selected source, confirming before discarding pending edits."
  (interactive)
  (zk-inbox-review--with-editor
   (when (or (not (plist-get (zk-inbox-review--draft) :dirty))
             (yes-or-no-p "Reload this item and discard its pending edits? "))
     (let ((key zk-inbox-review--selected))
       (remhash key zk-inbox-review--drafts)
       (zk-inbox-review--inventory)
       (unless (or (eq key 'new) (zk-inbox-review--entry)) (setq key 'new))
       (let ((zk-inbox-review--loading t)) (zk-inbox-review--select key))))))
(defun zk-inbox-review-open-source ()
  (interactive)
  (zk-inbox-review--with-editor
   (when-let* ((source (plist-get (zk-inbox-review--draft) :source)))
     (zk-inbox-review--remember) (zk-inbox-review--focus) (zk-ui-open source))))
(defun zk-inbox-review-open-result ()
  (interactive)
  (zk-inbox-review--with-editor
   (unless zk-inbox-review--last-result (user-error "No saved result yet"))
   (zk-inbox-review--focus) (zk-ui-open zk-inbox-review--last-result)))

(defun zk-inbox-review--validate (draft)
  (cond ((not (memq (plist-get draft :target) '(inbox agenda archive)))
         (user-error "Choose Inbox, Agenda or Archive"))
        ((string-empty-p (string-trim (plist-get draft :text)))
         (setq zk-inbox-review--error-field :text)
         (user-error "Write a message in the editor below"))
        ((and (eq (plist-get draft :target) 'agenda) (not (plist-get draft :destination)))
         (setq zk-inbox-review--error-field :destination)
         (user-error "Choose Location before saving"))
        ((and (eq (plist-get draft :target) 'agenda) (eq (plist-get draft :kind) 'event)
              (not (or
                    (and (plist-get draft :scheduled) (not (equal (plist-get draft :scheduled) "")))
                    (and (null (plist-get draft :scheduled))
                         (plist-get (plist-get draft :source) :scheduled)))))
         (setq zk-inbox-review--error-field :scheduled)
         (user-error "Choose Scheduled date/time for this event"))))

(defun zk-inbox-review-apply (&optional target-override)
  "Commit content and settings once, retaining drafts after failure.
TARGET-OVERRIDE applies a one-shot action without changing the draft's target."
  (interactive)
  (zk-inbox-review--with-editor
   (zk-inbox-review--remember)
   (let* ((draft (copy-sequence (zk-inbox-review--draft)))
          (draft (if target-override (plist-put draft :target target-override) draft))
          (source (plist-get draft :source))
          (key zk-inbox-review--selected) (target (plist-get draft :target))
          (index
           (cl-position key zk-inbox-review--entries :key (lambda (e) (plist-get e :ui-key)) :test
                        #'equal))
          result)
     (setq zk-inbox-review--error nil zk-inbox-review--error-field nil)
     (condition-case err
         (progn
           (zk-inbox-review--validate draft)
           (setq result (zk-inbox-submit
                         (plist-get draft :text) :reference source :target target
                         :destination (plist-get draft :destination) :kind
                         (plist-get draft :kind)
                         :state (plist-get draft :state)
                         :scheduled (plist-get draft :scheduled)
                         :deadline (plist-get draft :deadline))))
       (error (setq zk-inbox-review--error (error-message-string err))))
     (when result
       ;; Mark the operation complete before any UI work that might fail.
       (remhash key zk-inbox-review--drafts)
       (setq zk-inbox-review--last-result result
             zk-inbox-review--notice (format "%s: %s"
                                             (if (plist-get result :saved)
                                                 (if (eq target 'archive) "Archived" "Saved")
                                               "Updated in memory; save source/destination files")
                                             (or (plist-get result :filename)
                                                 (plist-get result :title))))
       (when (plist-get result :save-errors)
         (setq zk-inbox-review--notice
               (concat zk-inbox-review--notice " — "
                       (string-join (plist-get result :save-errors) "; "))))
       (condition-case err
           (progn
             (when (eq target 'agenda)
               (setq zk-inbox-review--last-destination
                     (or
                      (seq-find
                       (lambda (entry)
                         (equal (plist-get entry :path) (butlast (plist-get result :path))))
                       (zk-projects))
                      (plist-get draft :destination))))
             (zk-inbox-review--inventory)
             (let* ((stay (and source (eq target 'inbox)
                               (seq-find
                                (lambda (e) (equal (plist-get e :id) (plist-get result :id)))
                                zk-inbox-review--entries)))
                    (next (or stay (and source (nth (or index 0) zk-inbox-review--entries))))
                    (zk-inbox-review--loading t))
               (zk-inbox-review--select (if next (plist-get next :ui-key) 'new))))
         (error
          (let ((zk-inbox-review--loading t) (inhibit-read-only t)) (erase-buffer))
          (zk-inbox-review--set-editing nil)
          (setq zk-inbox-review--selected 'new
                zk-inbox-review--error
                (concat "Saved; queue refresh failed: " (error-message-string err))))))
     (zk-inbox-review--render) (zk-inbox-review--layout) (zk-inbox-review--focus)
     result)))

(defun zk-inbox-review-quit ()
  "Return to the previous layout while retaining all drafts."
  (interactive)
  (let (origin)
    (zk-inbox-review--with-editor
     (zk-inbox-review--remember)
     (setq origin zk-inbox-review--origin)
     (remove-hook 'window-size-change-functions #'zk-inbox-review--resized)
     (when zk-inbox-review--configuration
       (set-window-configuration zk-inbox-review--configuration)
       (setq zk-inbox-review--configuration nil)))
    (when (buffer-live-p origin) (switch-to-buffer origin))))
(defun zk-inbox-review--confirm-kill ()
  (or (not (zk-inbox-review--dirty-p)) (yes-or-no-p "Discard unsaved Inbox drafts? ")))
(defun zk-inbox-review--confirm-exit ()
  (if (get-buffer zk-inbox-review-buffer-name)
      (zk-inbox-review--with-editor (zk-inbox-review--confirm-kill))
    t))
(defun zk-inbox-review--cleanup ()
  (remove-hook 'window-size-change-functions #'zk-inbox-review--resized)
  (remove-hook 'kill-emacs-query-functions #'zk-inbox-review--confirm-exit)
  (when (timerp zk-inbox-review--resize-timer) (cancel-timer zk-inbox-review--resize-timer))
  (dolist (name (list zk-inbox-review--queue-name zk-inbox-review--controls-name))
    (when-let* ((buffer (get-buffer name))) (kill-buffer buffer))))

(defconst zk-inbox-review--browse-bindings
  '(("c" . zk-inbox-review-new) ("e" . zk-inbox-review-edit)
    ("i" . zk-inbox-review-keep) ("p" . zk-inbox-review-plan)
    ("a" . zk-inbox-review-archive) ("t" . zk-inbox-review-type)
    ("d" . zk-inbox-review-destination) ("w" . zk-inbox-review-state)
    ("s" . zk-inbox-review-schedule) ("l" . zk-inbox-review-deadline)
    ("S" . zk-inbox-review-clear-schedule) ("L" . zk-inbox-review-clear-deadline)
    ("j" . zk-inbox-review-jump) ("/" . zk-inbox-review-search)
    ("g" . zk-inbox-review-reload) ("o" . zk-inbox-review-open-source)
    ("v" . zk-inbox-review-open-result) ("q" . zk-inbox-review-quit)
    ("]" . zk-inbox-review-next) ("[" . zk-inbox-review-previous)
    ("M-n" . zk-inbox-review-next) ("M-p" . zk-inbox-review-previous)
    ("RET" . zk-inbox-review-apply) ("C-x C-s" . zk-inbox-review-apply)))

(defvar zk-inbox-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map org-mode-map)
    (dolist (binding zk-inbox-review--browse-bindings)
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(defvar zk-inbox-review-edit-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map org-mode-map)
    (define-key map (kbd "C-c C-c") #'zk-inbox-review-finish-edit)
    (define-key map (kbd "<escape>") #'zk-inbox-review-finish-edit)
    (define-key map (kbd "C-x C-s") #'zk-inbox-review-apply)
    map))

(defun zk-inbox-review--set-editing (editing)
  "Change only editing state and keymap, retaining text, undo and selection."
  (setq zk-inbox-review--editing editing buffer-read-only (not editing))
  (use-local-map (if editing zk-inbox-review-edit-map zk-inbox-review-mode-map))
  (setq-local mode-line-format
              (if editing '("  Inbox EDITING   C-c C-c / ESC Finish   C-x C-s Save")
                '("  Inbox BROWSE   e Edit   RET Save   [ / ] Items   q Back"))))

(defun zk-inbox-review-edit ()
  "Explicitly enable text editing for the current draft."
  (interactive)
  (zk-inbox-review--with-editor
   (zk-inbox-review--set-editing t)
   (zk-inbox-review--render) (zk-inbox-review--layout))
  (zk-inbox-review--focus))

(defun zk-inbox-review-finish-edit ()
  "Return to browsing, keeping edited text as an unsubmitted draft."
  (interactive)
  (zk-inbox-review--with-editor
   (zk-inbox-review--remember)
   (zk-inbox-review--set-editing nil)
   (zk-inbox-review--render) (zk-inbox-review--layout))
  (zk-inbox-review--focus))

(defun zk-inbox-review-clear-schedule ()
  (interactive) (zk-inbox-review--set :scheduled ""))
(defun zk-inbox-review-clear-deadline ()
  (interactive) (zk-inbox-review--set :deadline ""))

(defun zk-inbox-review--panel-keymap ()
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding zk-inbox-review--browse-bindings)
      (define-key map (kbd (car binding)) (cdr binding)))
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map))

(define-derived-mode zk-inbox-review-panel-mode special-mode "Inbox settings"
  (use-local-map (zk-inbox-review--panel-keymap))
  (setq-local header-line-format nil left-fringe-width 0 right-fringe-width 0
              left-margin-width 2 right-margin-width 2 truncate-lines t mode-line-format nil))
(define-derived-mode zk-inbox-review-queue-mode zk-inbox-review-panel-mode "Inbox queue"
  (setq-local mode-line-format '("  Inbox   M-n / M-p")))

(define-derived-mode zk-inbox-review-mode org-mode "ZK Inbox"
  "Browse Inbox items; enter editing explicitly with e."
  (setq-local header-line-format nil left-fringe-width 0 right-fringe-width 0
              left-margin-width 2 right-margin-width 2
              default-directory (file-name-as-directory zk-root)
              zk-inbox-review--drafts (make-hash-table :test #'equal))
  (zk-inbox-review--set-editing nil)
  (visual-line-mode 1)
  (add-hook 'after-change-functions #'zk-inbox-review--changed nil t)
  (add-hook 'kill-buffer-query-functions #'zk-inbox-review--confirm-kill nil t)
  (add-hook 'kill-buffer-hook #'zk-inbox-review--cleanup nil t)
  (add-hook 'kill-emacs-query-functions #'zk-inbox-review--confirm-exit))

(defun zk-inbox-review-open (&optional selected)
  "Open SELECTED Inbox entry, or the new-item draft when SELECTED is nil."
  (let ((configuration (current-window-configuration)) (origin (current-buffer))
        (buffer (get-buffer-create zk-inbox-review-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'zk-inbox-review-mode) (zk-inbox-review-mode))
      (unless zk-inbox-review--configuration
        (setq zk-inbox-review--configuration configuration zk-inbox-review--origin origin))
      (zk-inbox-review--inventory))
    (if-let* ((window (get-buffer-window buffer))) (select-window window)
      (pop-to-buffer-same-window buffer))
    (let
        ((key
          (and selected
               (seq-find (lambda (entry) (zk-inbox-review--same selected entry))
                         zk-inbox-review--entries))))
      (zk-inbox-review--select (if key (plist-get key :ui-key) 'new)))
    (add-hook 'window-size-change-functions #'zk-inbox-review--resized)
    buffer))

(provide 'zk-inbox-review)
;;; zk-inbox-review.el ends here
