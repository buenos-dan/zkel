;;; zk-org.el --- Org appearance and editing defaults -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared Org preferences for every Org buffer, enabled explicitly by zk-mode.
;; Loading this module defines options; it does not install hooks or preferences.

;;; Code:
(require 'zk-library)
(require 'org)
(require 'org-indent)
(require 'org-agenda)
(require 'disp-table)

(defcustom zk-org-todo-keywords
  '(sequence "TODO(t)" "NEXT(n)" "|" "DONE(d)")
  "Org keyword sequence shared by parsing, validation and state selection."
  :type 'sexp :group 'zk)

(defun zk-org-states (&optional subset)
  "Return state names from `zk-org-todo-keywords'.
SUBSET is active, done, or nil for all states."
  (let (done names)
    (dolist (keyword (cdr zk-org-todo-keywords))
      (if (equal keyword "|") (setq done t)
        (when (or (null subset) (if (eq subset 'done) done (not done)))
          (push (replace-regexp-in-string "(.*\\'" "" keyword) names))))
    (nreverse names)))

(defun zk-org-todo-sequence (_sequence)
  "Supply the package's locally configured Org state sequence."
  zk-org-todo-keywords)

(defface zk-org-todo
  '((((background dark)) (:foreground "#9EB9D0" :weight normal))
    (((background light)) (:foreground "#4B647C" :weight normal))
    (t (:inherit font-lock-type-face :weight normal)))
  "Muted blue for organized work waiting to be selected." :group 'zk)
(defface zk-org-next
  '((((background dark)) (:foreground "#F2B36D" :weight bold))
    (((background light)) (:foreground "#A44B12" :weight bold))
    (t (:inherit warning :weight bold)))
  "Amber emphasis for the next executable task." :group 'zk)
(defface zk-org-finished
  '((((background dark)) (:foreground "#969696" :weight normal))
    (((background light)) (:foreground "#747474" :weight normal))
    (t (:inherit shadow :weight normal)))
  "Quiet completed tasks." :group 'zk)

(defcustom zk-org-indent-width 2
  "Indentation per Org heading level." :type 'natnum :group 'zk)
(defcustom zk-org-ellipsis "…"
  "Folded Org text indicator." :type 'string :group 'zk)
(defcustom zk-org-inline-images t
  "Display inline images by default when opening Org files." :type 'boolean :group 'zk)
(defcustom zk-org-keep-completed t
  "Keep completed items on their original Agenda dates." :type 'boolean :group 'zk)

(defvar zk-org--enabled nil)
(defvar zk-org--defaults nil)
(defvar zk-org--faces nil)
(defvar-local zk-org--buffer-state nil)
(defconst zk-org--local-options
  '(org-startup-indented org-indent-indentation-per-level org-hide-leading-stars
    org-ellipsis buffer-display-table org-adapt-indentation indent-tabs-mode))

(defun zk-org--ellipsis-state ()
  (delq nil
        (mapcar (lambda (alias)
                  (when-let* ((spec (org-fold-core-get-folding-spec-from-alias alias)))
                    (cons alias (org-fold-core-get-folding-spec-property spec :ellipsis))))
                '(outline block drawer))))

(defun zk-org--local-setting (symbol)
  (list symbol (local-variable-p symbol) (symbol-value symbol)))

(defun zk-org--restore-settings (settings)
  (dolist (setting settings)
    (if (nth 1 setting) (set (make-local-variable (car setting)) (nth 2 setting))
      (kill-local-variable (car setting)))))

(defun zk-org--image-variable ()
  "Return the preview overlay variable for the installed Org version."
  (if (boundp 'org-link-preview-overlays) 'org-link-preview-overlays 'org-inline-image-overlays))

(defun zk-org--show-images ()
  "Refresh inline image previews with the API provided by this Org version."
  (funcall (if (fboundp 'org-link-preview-region) 'org-link-preview-region
             'org-display-inline-images) nil t))

(defun zk-org--default (symbol value)
  "Set SYMBOL's default to VALUE once, recording the value being replaced."
  (unless (assq symbol zk-org--defaults)
    (push (list symbol (default-value symbol) value) zk-org--defaults))
  (set-default symbol value))

(defun zk-org--prepare (&rest _)
  "Remember local display settings before changing them."
  (when (and zk-org--enabled (derived-mode-p 'org-mode)
             (not org-inhibit-startup) (not zk-org--buffer-state))
    (setq zk-org--buffer-state
          (list :settings (mapcar #'zk-org--local-setting zk-org--local-options)
                :indent org-indent-mode :images (copy-sequence (symbol-value (zk-org--image-variable)))
                :ellipsis (zk-org--ellipsis-state)))))

(defun zk-org--outline-options (&rest _)
  "Keep Org outline display consistent after file startup options are read."
  (when (and zk-org--enabled (derived-mode-p 'org-mode) (not org-inhibit-startup))
    (zk-org--prepare)
    (setq-local org-startup-indented t org-indent-indentation-per-level zk-org-indent-width
                org-hide-leading-stars t org-ellipsis zk-org-ellipsis)))

(defun zk-org--display ()
  "Apply Org presentation without changing source text or folding."
  (when (and zk-org--enabled (derived-mode-p 'org-mode) (not org-inhibit-startup))
    (zk-org--outline-options)
    (unless (plist-get zk-org--buffer-state :ellipsis)
      (setq zk-org--buffer-state (plist-put zk-org--buffer-state :ellipsis (zk-org--ellipsis-state))))
    (unless org-indent-mode (org-indent-mode 1))
    (org-indent--compute-prefixes)
    (dolist (alias '(outline block drawer))
      (when-let* ((spec (org-fold-core-get-folding-spec-from-alias alias)))
        (org-fold-core-set-folding-spec-property spec :ellipsis zk-org-ellipsis)))
    (setq-local buffer-display-table
                (if buffer-display-table (copy-sequence buffer-display-table) (make-display-table)))
    (set-display-table-slot buffer-display-table 'selective-display
                            (vconcat (mapcar (lambda (char) (make-glyph-code char 'org-ellipsis))
                                             (string-to-list zk-org-ellipsis))))
    (when (and org-startup-with-inline-images (display-graphic-p))
      (zk-org--show-images))
    (setq zk-org--buffer-state
          (plist-put zk-org--buffer-state :applied (mapcar #'zk-org--local-setting zk-org--local-options)))
    (font-lock-flush)))

(defun zk-org--restore-buffer ()
  "Restore the display state captured for the current Org buffer."
  (when zk-org--buffer-state
    (let* ((state zk-org--buffer-state)
           (settings (mapcar
                      (lambda (old)
                        (let ((current (zk-org--local-setting (car old)))
                              (applied (assq (car old) (plist-get state :applied))))
                          (if (and applied (not (equal current applied))) current old)))
                      (plist-get state :settings))))
      (setq zk-org--buffer-state nil)
      (when (derived-mode-p 'org-mode)
        (dolist (overlay (symbol-value (zk-org--image-variable)))
          (unless (memq overlay (plist-get state :images)) (delete-overlay overlay)))
        (set (zk-org--image-variable) (seq-filter #'overlay-buffer (plist-get state :images)))
        (org-indent-mode -1)
        (org-set-regexps-and-options)
        (zk-org--restore-settings settings)
        (when (plist-get state :indent) (org-indent-mode 1))
        (zk-org--restore-settings settings)
        (dolist (pair (plist-get state :ellipsis))
          (when-let* ((spec (org-fold-core-get-folding-spec-from-alias (car pair))))
            (org-fold-core-set-folding-spec-property spec :ellipsis (cdr pair))))
        (font-lock-flush)))))

(defun zk-org-enable ()
  "Enable Org defaults and presentation, including already open buffers."
  (unless zk-org--enabled
    (setq zk-org--enabled t)
    ;; Capture existing buffers before replacing inherited defaults.
    (dolist (buffer (buffer-list)) (with-current-buffer buffer (zk-org--prepare)))
    (dolist (option `((org-startup-indented . t)
                      (org-indent-indentation-per-level . ,zk-org-indent-width)
                      (org-hide-leading-stars . t) (org-ellipsis . ,zk-org-ellipsis)
                      (org-startup-with-inline-images . ,zk-org-inline-images)
                      (org-todo-keywords . (,zk-org-todo-keywords))
                      (org-log-done . time)
                      (org-log-repeat . time)
                      (org-agenda-skip-scheduled-if-done . ,(not zk-org-keep-completed))
                      (org-agenda-skip-deadline-if-done . ,(not zk-org-keep-completed))
                      (org-agenda-skip-timestamp-if-done . ,(not zk-org-keep-completed))))
      (zk-org--default (car option) (cdr option)))
    (let ((faces (copy-tree (default-value 'org-todo-keyword-faces))))
      (setf (alist-get "TODO" faces nil nil #'equal) 'zk-org-todo
            (alist-get "NEXT" faces nil nil #'equal) 'zk-org-next
            (alist-get "DONE" faces nil nil #'equal) 'zk-org-finished)
      (zk-org--default 'org-todo-keyword-faces faces))
    (dolist (pair '((org-todo . zk-org-todo) (org-done . zk-org-finished)
                    (org-agenda-done . zk-org-finished)))
      (let* ((face (car pair))
             (spec (list (list t (list :inherit (cdr pair) :foreground 'unspecified :weight 'normal)))))
        (push (list face (get face 'face-override-spec) spec) zk-org--faces)
        (face-spec-set face spec)))
    (advice-add 'org-set-regexps-and-options :before #'zk-org--prepare)
    (advice-add 'org-set-regexps-and-options :after #'zk-org--outline-options)
    (add-hook 'org-mode-hook #'zk-org--display)
    (add-hook 'find-file-hook #'zk-org--display 90)
    (add-hook 'after-revert-hook #'zk-org--display 90)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'org-mode)
          (org-set-regexps-and-options) (zk-org--display))))))

(defun zk-org-disable ()
  "Remove ZK presentation and restore defaults still owned by this module."
  (when zk-org--enabled
    (setq zk-org--enabled nil)
    (advice-remove 'org-set-regexps-and-options #'zk-org--prepare)
    (advice-remove 'org-set-regexps-and-options #'zk-org--outline-options)
    (remove-hook 'org-mode-hook #'zk-org--display)
    (remove-hook 'find-file-hook #'zk-org--display)
    (remove-hook 'after-revert-hook #'zk-org--display)
    (dolist (setting zk-org--defaults)
      (when (equal (default-value (car setting)) (nth 2 setting))
        (set-default (car setting) (nth 1 setting))))
    (dolist (setting zk-org--faces)
      (when (equal (get (car setting) 'face-override-spec) (nth 2 setting))
        (face-spec-set (car setting) (nth 1 setting))))
    (setq zk-org--defaults nil zk-org--faces nil)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer (zk-org--restore-buffer)))))

(provide 'zk-org)
;;; zk-org.el ends here
