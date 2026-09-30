;;; zk-agenda.el --- Native Org calendar projection -*- lexical-binding: t; -*-

;;; Commentary:
;; Native Org calendar projection

;;; Code:
(require 'zk-org-store)
(require 'org-agenda)

(defun zk-agenda-files ()
  "Only organized agenda entries participate in the calendar."
  (seq-filter #'file-readable-p (list (zk-agenda-path))))

(defun zk-agenda--display-line (start end)
  "Copy native Agenda styling without importing its commands or buffer state."
  (let* ((text (buffer-substring start end)) (pos 0))
    (while (< pos (length text))
      (let ((next (next-property-change pos text (length text))) properties)
        (dolist (property '(face font-lock-face display))
          (when-let* ((value (get-text-property pos property text)))
            (setq properties (append properties (list property value)))))
        (set-text-properties pos next properties text)
        (setq pos next)))
    text))

(defun zk-agenda-range (view &optional day)
  "Return (START . DAYS) for VIEW containing DAY, an absolute Org day.
Weeks run Monday through Sunday. Years include January 1 through December 31."
  (let* ((day (or day (org-today)))
         (date (calendar-gregorian-from-absolute day))
         (year (nth 2 date)))
    (pcase view
      ('day (cons day 1))
      ('week (cons (- day (mod (1- (calendar-day-of-week date)) 7)) 7))
      ('year (let ((start (calendar-absolute-from-gregorian (list 1 1 year))))
               (cons start (- (calendar-absolute-from-gregorian (list 1 1 (1+ year))) start))))
      (_ (user-error "Choose day, week or year")))))

(defun zk-agenda--build-rows (view width range)
  "Return native Agenda rows for VIEW and RANGE at WIDTH.
Each row has :text and :kind; event rows also carry :entry and :native-text.
Calendar generation leaves the user's window layout and selection unchanged."
  (let ((org-agenda-files (zk-agenda-files))
        (org-agenda-buffer-name (generate-new-buffer-name " *zk-calendar-query*"))
        (org-agenda-window-setup 'current-window)
        (org-agenda-span (cdr range)) (org-agenda-start-on-weekday nil)
        (org-agenda-start-day nil) (org-agenda-sticky nil)
        (org-agenda-overriding-arguments nil)
        (org-agenda-show-all-dates t)
        (org-agenda-mode-hook nil) (org-agenda-finalize-hook nil)
        (org-agenda-inhibit-startup t) (org-agenda-use-tag-inheritance t)
        (org-agenda-use-time-grid t)
        (org-agenda-time-grid (cons (if (eq view 'day) '(daily today) '(today require-timed))
                                    (cdr org-agenda-time-grid)))
        (org-agenda-tags-column (if width (- (max 24 (1- width))) org-agenda-tags-column))
        (system-time-locale "C") rows)
    (unwind-protect
        (save-window-excursion
          (save-current-buffer
            (org-agenda-list nil (car range) (cdr range))
            (goto-char (point-min))
            (while (< (point) (point-max))
              (let* ((start (point)) (end (line-end-position))
                     (marker (or (get-text-property start 'org-hd-marker)
                                 (get-text-property start 'org-marker)))
                     (entry (when (and (markerp marker) (buffer-live-p (marker-buffer marker)))
                              (with-current-buffer (marker-buffer marker)
                                (org-with-wide-buffer
                                 (goto-char marker)
                                 (when (org-at-heading-p) (zk-org-entry)))))))
                (unless (or (= start end) (get-text-property start 'org-agenda-structural-header))
                  (push (list :text (zk-agenda--display-line start end)
                              :kind (cond (entry 'event)
                                          ((get-text-property start 'org-agenda-date-header) 'date)
                                          (t 'grid))
                              :entry entry
                              ;; Our marker is independent of Org's query-buffer cleanup.
                              :source-marker (when entry (copy-marker marker))
                              :native-text (when entry (buffer-substring start end)))
                        rows)))
              (forward-line 1))))
      (when-let* ((buffer (get-buffer org-agenda-buffer-name))) (kill-buffer buffer)))
    (nreverse rows)))

(defun zk-today-items ()
  "Return today's actual entries for callers that do not need display rows."
  (delq nil (mapcar (lambda (row)
                      (when-let* ((entry (plist-get row :entry)))
                        (append
                         (list :text (string-trim (substring-no-properties (plist-get row :text))))
                         entry)))
                    (zk-agenda-day-rows))))

(defun zk-agenda-edit-row (row command &optional prefix)
  "Run native Agenda COMMAND against ROW without displaying an Agenda buffer.
PREFIX is passed unchanged to the native interactive command. The hidden
command buffer retains Org's source markers and formatting metadata."
  (unless (memq command '(org-agenda-todo org-agenda-schedule org-agenda-deadline))
    (user-error "Unsupported inline Agenda command"))
  (let* ((entry (plist-get row :entry))
         (native (plist-get row :native-text))
         (marker (and entry (zk-org-resolve entry)))
         (file (and marker (buffer-file-name (marker-buffer marker))))
         (tick (and marker (with-current-buffer (marker-buffer marker) (buffer-chars-modified-tick)))))
    (unless (and marker native) (user-error "Place point on an Agenda entry"))
    (zk-org-transaction
     (list file)
     (lambda ()
       (with-temp-buffer
         (let ((org-agenda-mode-hook nil) (org-agenda-finalize-hook nil)
               (org-agenda-loop-over-headlines-in-active-region nil)
               ;; Remote undo belongs to a persistent Agenda view, not this
               ;; temporary projection. Source-buffer undo remains available.
               (org-agenda-allow-remote-undo nil)
               (org-agenda-window-setup 'current-window))
           (org-agenda-mode)
           (setq-local org-agenda-type 'agenda)
           (let ((inhibit-read-only t))
             (insert native "\n")
             ;; Agenda generation releases its own marker table on cleanup.
             ;; Resolve the checked snapshot again instead of using dead markers.
             (add-text-properties (point-min) (point-max)
                                  (list 'org-marker (copy-marker marker)
                                        'org-hd-marker (copy-marker marker))))
           (goto-char (point-min))
           (let ((current-prefix-arg prefix))
             (call-interactively command))))
       (with-current-buffer (marker-buffer marker)
         (org-with-wide-buffer
          (goto-char marker)
          (append (zk-org-entry) (list :changed (/= tick (buffer-chars-modified-tick))))))))))

;;;###autoload
(defun zk-agenda-view (&optional view)
  "Open a standalone native Agenda for VIEW (day, week or year).
For existing callers, nil means day and t means week."
  (interactive)
  (let* ((view (pcase view ('nil 'day) ('t 'week) (_ view)))
         (range (zk-agenda-range view)))
    (let ((org-agenda-files (zk-agenda-files))
          (org-agenda-window-setup 'current-window)
          (org-agenda-overriding-arguments nil)
          (org-agenda-inhibit-startup t)
          (org-agenda-start-on-weekday nil)
          (org-agenda-show-all-dates (if (eq view 'year) nil org-agenda-show-all-dates))
          (org-agenda-use-time-grid (if (eq view 'year) nil org-agenda-use-time-grid))
          (org-agenda-overriding-header
           (if (eq view 'year)
               (format "Agenda — %d" (nth 2 (calendar-gregorian-from-absolute (car range))))
             org-agenda-overriding-header)))
      (org-agenda-list nil (car range) (cdr range)))
    (when (eq view 'year)
      ;; Keep the annual summary compact after native Agenda redo.
      (setq-local org-agenda-show-all-dates nil org-agenda-use-time-grid nil
                  org-agenda-overriding-header
                  (format "Agenda — %d" (nth 2 (calendar-gregorian-from-absolute (car range))))))
    ;; Native redo evaluates this per-row form. Re-enter the view so its source
    ;; files and yearly compaction remain in effect after refreshing.
    (let ((inhibit-read-only t))
      (put-text-property (point-min) (point-max) 'org-redo-cmd
                         (list 'zk-agenda-view (list 'quote view))))))

(defvar zk-agenda--cache nil
  "At most one (KEY . ROWS) cache entry per inline day/week view.")

(defun zk-agenda-clear-cache ()
  "Discard all calendar projections."
  (setq zk-agenda--cache nil))

(defun zk-agenda-rows (&optional view width)
  "Return the native day or week projection, cached independently."
  (let* ((view (or view 'day))
         (_ (unless (memq view '(day week)) (user-error "Inline Agenda supports day or week")))
         (range (zk-agenda-range view))
         (key (list range (format-time-string "%Y-%m-%d %H:%M") width
                    org-agenda-time-grid org-agenda-current-time-string
                    org-agenda-prefix-format org-agenda-format-date
                    org-agenda-skip-scheduled-if-done org-agenda-skip-deadline-if-done
                    org-agenda-skip-timestamp-if-done
                    org-agenda-tags-column (zk-library-file-version (zk-agenda-path))))
         (cached (alist-get view zk-agenda--cache)))
    (unless (equal key (car cached))
      (setq cached (cons key (zk-agenda--build-rows view width range)))
      ;; The first build may visit the source file. Cache its resulting buffer
      ;; version so returning from another view does not rebuild it needlessly.
      (setcar (last key) (zk-library-file-version (zk-agenda-path)))
      (setf (alist-get view zk-agenda--cache) cached))
    (cdr cached)))

(defun zk-agenda-day-rows (&optional width)
  "Return today's native rows for API callers, independent of Home's view."
  (zk-agenda-rows 'day width))

(provide 'zk-agenda)
;;; zk-agenda.el ends here
