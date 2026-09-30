;;; zk-startup-tests.el --- Package activation without a manual load path -*- lexical-binding: t; -*-
(require 'ert)
(require 'package)

(defconst zk-startup-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(ert-deftest zk-startup-package-activation-loads-commands-without-L ()
  "Exercise package activation in a fresh Emacs, not this runner's load path."
  (let* ((directory (make-temp-file "zk-startup-" t))
         (packages (expand-file-name "elpa" directory))
         (package-directory (expand-file-name "zk-0.2.0" packages))
         (script (expand-file-name "check.el" directory))
         (emacs (expand-file-name invocation-name invocation-directory)))
    (unwind-protect
        (progn
          (make-directory package-directory t)
          (dolist (file (directory-files zk-startup-test--root t "\\.el\\'"))
            (unless (string-suffix-p "-pkg.el" file)
              (copy-file file (expand-file-name (file-name-nondirectory file) package-directory))))
          ;; An installed checkout already has autoloads: test those unchanged.
          ;; A fresh clone uses package.el, just as installation would.
          (unless (file-exists-p (expand-file-name "zk-autoloads.el" package-directory))
            (package-generate-autoloads "zk" package-directory))
          (with-temp-file (expand-file-name "zk-pkg.el" package-directory)
            (insert "(define-package \"zk\" \"0.2.0\" \"ZK\" '((emacs \"30.1\")))\n"))
          (with-temp-file script
            (prin1 `(setq user-emacs-directory ,directory
                          package-user-dir ,packages package-directory-list nil
                          package-enable-at-startup nil package-quickstart nil) (current-buffer))
            (insert "\n(require 'package)\n(package-initialize)\n"
                    "(unless (locate-library \"zk\") (error \"Activated ZK is missing from load-path\"))\n"
                    "(unless (and (commandp 'zk-home) (commandp 'zk-find-note) (commandp 'zk-menu))\n"
                    "  (error \"ZK command autoloads are missing\"))\n"
                    "(require 'org)\n"
                    "(let ((before org-startup-with-inline-images))\n"
                    "  (require 'zk)\n"
                    "  (unless (eq before org-startup-with-inline-images) (error \"Loading applied Org settings\")))\n"
                    "(zk-mode 1)\n"
                    "(unless (featurep 'zk-org-store) (error \"Org storage module missing\"))\n"
                    "(with-temp-buffer (org-mode)\n"
                    "  (unless (and org-indent-mode org-startup-with-inline-images (equal org-ellipsis \"…\"))\n"
                    "    (error \"Org profile missing without init-org.el\")))\n"
                    "(unless (equal org-agenda-files (list (zk-agenda-path))) (error \"Agenda source missing\"))\n"
                    "(unless zk-mode (error \"ZK mode failed to enable\"))\n"
                    "(zk-mode -1)\n(princ \"ZK cold activation passed\\n\")\n"))
          (with-temp-buffer
            (let ((exit-code (call-process emacs nil (current-buffer) nil "-Q" "--batch" "-l" script)))
              (ert-info ((buffer-string)) (should (equal exit-code 0)))
              (should (string-match-p "ZK cold activation passed" (buffer-string))))))
      (delete-directory directory t))))
