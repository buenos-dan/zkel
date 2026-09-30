;;; zk-note-create-tests.el --- Filename-driven creation -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-note-create-org-uses-exact-name-and-file-level-properties ()
  (zk-test-library
   (let* ((note (zk-note-create "中文 Mac config.org"))
          (file (plist-get note :file)))
     (should (equal file (zk-path "org-notes/中文 Mac config.org")))
     (should (plist-get note :saved))
     (with-current-buffer (get-file-buffer file)
       (goto-char (point-min))
       (should (org-before-first-heading-p))
       (should (equal (org-entry-get nil "ID") (plist-get note :id)))
       (should (equal (org-entry-get nil "ZK_TYPE") "fleeting-note"))
       (should (equal (org-entry-get nil "MDS" nil t) "nil"))
       (should (equal (org-entry-get nil "TOPICS" nil t) "nil"))
       (should (equal (org-entry-get nil "DATE") (format-time-string "%Y-%m-%d")))
       (should-not (re-search-forward org-heading-regexp nil t))
       (should-not (string-match-p "#\\+title:" (buffer-string))))
     (let ((marker (zk-org-locate (plist-get note :id))))
       (should (eq (marker-buffer marker) (get-file-buffer file)))
       (should (= 1 (marker-position marker)))))))

(ert-deftest zk-note-create-markdown-remains-empty-and-keeps-its-mode ()
  (zk-test-library
   (let* ((auto-mode-alist (cons '("\\.md\\'" . text-mode) auto-mode-alist))
          (note (zk-note-create "quick idea.md"))
          (file (plist-get note :file)))
     (should (equal file (zk-path "md-notes/quick idea.md")))
     (should-not (plist-get note :id))
     (with-current-buffer (get-file-buffer file)
       (should (eq major-mode 'text-mode))
       (should (string-empty-p (buffer-string))))
     (should (file-exists-p file))
     (should (equal "quick idea.md" (plist-get (car (zk-notes)) :filename))))))

(ert-deftest zk-note-create-same-basename-in-both-formats-and-distinct-ids ()
  (zk-test-library
   (let ((a (zk-note-create "idea.org")) (b (zk-note-create "another.org"))
         (md (zk-note-create "idea.md" "# Draft\nText")))
     (should-not (equal (plist-get a :id) (plist-get b :id)))
     (should (string-prefix-p "# Draft" (plist-get (zk-entry-read md) :body)))
     (should (= 3 (length (zk-notes)))))))

(ert-deftest zk-note-create-rejects-invalid-names-before-touching-files ()
  (zk-test-library
   (dolist (filename '("" "missing-extension" ".org" ".hidden.org" "../escape.org"
                       "nested/file.org" "nested\\file.org" "/absolute.org" "~bad.org"
                       "bad\nname.org" "bad\rname.md" "bad\0name.org" "bad.txt"
                       "name.org " " name.org" "bad.ORG"))
     (should-error (zk-note-create filename) :type 'user-error))
   (should-not (file-exists-p (zk-path zk-org-note-directory)))
   (should-not (file-exists-p (zk-path zk-markdown-note-directory)))))

(ert-deftest zk-note-create-does-not-overwrite-existing-file-or-unsaved-buffer ()
  (zk-test-library
   (let ((file (zk-test-write (zk-path "org-notes/existing.org") "Keep exactly this\n")))
     (should-error (zk-note-create "existing.org") :type 'user-error)
     (with-temp-buffer (insert-file-contents file) (should (equal "Keep exactly this\n" (buffer-string)))))
   (let* ((file (zk-path "org-notes/draft.org")) (buffer (find-file-noselect file)))
     (with-current-buffer buffer (insert "Unsaved"))
     (should-error (zk-note-create "draft.org") :type 'user-error)
     (with-current-buffer buffer (should (equal "Unsaved" (buffer-string))) (should (buffer-modified-p)))
     (should-not (file-exists-p file)))))

(ert-deftest zk-note-command-prompts-for-filename-once-and-opens-body ()
  (zk-test-library
   (let (prompts)
     (cl-letf (((symbol-function 'read-string)
                (lambda (prompt &rest _) (push prompt prompts) "input.org")))
       (call-interactively #'zk-new-note))
     (should (equal '("Note filename (.org or .md): ") prompts))
     (should (equal buffer-file-name (zk-path "org-notes/input.org")))
     (should (= (point) (point-max))))))

(ert-deftest zk-note-extraction-promotes-children-and-retains-metadata-and-id-links ()
  (zk-test-library
   (let* ((entry (zk-capture "Root title"
                             "Text\n*** Child\n:PROPERTIES:\n:ID: child-id\n:END:\n**** Grandchild\nMore\n" "request-42")))
     (with-current-buffer (zk-org-buffer (zk-inbox-path))
       (goto-char (zk-org-locate entry))
       (org-entry-put nil "MDS" "025.4") (org-set-tags '("reading"))
       (setq entry (zk-org-entry)))
     (let ((note (zk-inbox-to-note entry "classified.org")))
       (should-not (zk-inbox-entries))
       (should (equal (plist-get entry :id) (plist-get note :id)))
       (with-current-buffer (get-file-buffer (plist-get note :file))
         (goto-char (point-min))
         (should (equal (org-entry-get nil "MDS") "025.4"))
         (should (equal (org-entry-get nil "ZK_REQUEST") "request-42"))
         (should (member "reading" (plist-get note :tags)))
         (should (re-search-forward "^\\* Child$" nil t))
         (should (equal (org-entry-get nil "ID") "child-id"))
         (should (re-search-forward "^\\*\\* Grandchild$" nil t))
         (should-not (string-match-p "Root title" (buffer-string))))
       (let ((again (zk-capture "Root title" nil "request-42")))
         (should (plist-get again :duplicate))
         (should-not (zk-inbox-entries)))))))

(ert-deftest zk-note-extraction-collision-keeps-source-intact ()
  (zk-test-library
   (let ((entry (zk-capture "Keep" "Body")))
     (zk-note-create "exists.org")
     (should-error (zk-inbox-to-note entry "exists.org") :type 'user-error)
     (should-error (zk-inbox-to-note entry "conversion.md") :type 'user-error)
     (should (equal (plist-get entry :id) (plist-get (car (zk-inbox-entries)) :id)))
     (should (= 1 (length (zk-notes)))))))
