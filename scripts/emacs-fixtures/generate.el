;;; generate.el --- Generate golden fixtures from real Emacs Denote -*- lexical-binding: t -*-

;; Usage (from the repository root):
;;
;;   emacs --batch -Q -l scripts/emacs-fixtures/generate.el
;;
;; or simply `make fixtures'.
;;
;; Denote is installed hermetically from GNU ELPA into
;; `.cache/emacs-fixtures/elpa' (see install.el); ~/.emacs.d is never
;; touched.  Every note is created in a fresh temporary directory that is
;; deleted afterwards.  The output is written to
;; tests/fixtures/emacs/denote.json and consumed by
;; tests/spec/emacs_parity_spec.lua.
;;
;; Everything that could make the output non-deterministic is pinned:
;; the time zone (TZ below), the dates (fixed Unix timestamps) and the
;; collation locale (LC_ALL=C, so `string-collate-lessp' sorts bytewise).

(setenv "LC_ALL" "C")
(setenv "LANG" "C")

(load (expand-file-name "install.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(require 'denote)
(require 'json)
(require 'seq)

;;;; Determinism

(defconst denote-fixtures-tz "Asia/Kolkata"
  "Time zone used for every date (non-zero, non-whole-hour offset: +05:30).")

(setenv "TZ" denote-fixtures-tz)
(set-time-zone-rule denote-fixtures-tz)

(defconst denote-fixtures-output
  (expand-file-name "tests/fixtures/emacs/denote.json" denote-fixtures-root))

(defconst denote-fixtures-file-types '(org markdown-yaml markdown-toml text))

;; Fixed dates (Unix epoch seconds).
(defconst denote-fixtures-epoch-a 1709627829) ; 2024-03-05 14:07:09 +05:30
(defconst denote-fixtures-epoch-b 1735669800) ; 2025-01-01 00:00:00 +05:30
(defconst denote-fixtures-epoch-c 1782889200) ; 2026-07-01 12:30:00 +05:30

(defun denote-fixtures-version ()
  "Return the installed Denote version as a string."
  (package-version-join (package-desc-version (cadr (assq 'denote package-alist)))))

;;;; Helpers

(defun denote-fixtures--vec (list)
  "Return LIST as a vector so that it encodes as a JSON array."
  (vconcat list))

(defun denote-fixtures--bool (v)
  (if v t :json-false))

(defmacro denote-fixtures--with-denote-dir (var &rest body)
  "Bind VAR to a fresh temporary `denote-directory' and run BODY."
  (declare (indent 1))
  `(let* ((,var (file-name-as-directory (make-temp-file "denote-fixtures-" t)))
          (denote-directory ,var)
          (denote-save-buffers t)
          (denote-kill-buffers t)
          (denote-used-identifiers nil))
     (unwind-protect
         (progn ,@body)
       (dolist (buf (buffer-list))
         (when-let* ((f (buffer-file-name buf)))
           (when (string-prefix-p ,var f)
             (with-current-buffer buf (set-buffer-modified-p nil))
             (kill-buffer buf))))
       (delete-directory ,var t))))

(defun denote-fixtures--read-file (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (buffer-string)))

(defun denote-fixtures--create (input file-type)
  "Create a note with `denote' from INPUT (a plist) for FILE-TYPE.
Return (FILENAME . CONTENTS)."
  (denote-fixtures--with-denote-dir dir
    (let* ((path (denote (plist-get input :title)
                         (plist-get input :keywords)
                         file-type
                         dir
                         (plist-get input :date)
                         nil
                         (plist-get input :signature)
                         nil)))
      (cons (file-name-nondirectory path) (denote-fixtures--read-file path)))))

(defun denote-fixtures--input-json (input)
  `(("title" . ,(or (plist-get input :title) ""))
    ("keywords" . ,(denote-fixtures--vec (plist-get input :keywords)))
    ("signature" . ,(or (plist-get input :signature) ""))
    ("date" . ,(plist-get input :date))))

;;;; Case tables

(defconst denote-fixtures-note-cases
  `(("basic" :title "Hello World" :keywords ("emacs" "neovim") :date ,denote-fixtures-epoch-a)
    ("no-keywords" :title "Just a title" :keywords nil :date ,denote-fixtures-epoch-a)
    ("empty-title" :title "" :keywords ("journal") :date ,denote-fixtures-epoch-b)
    ("only-identifier" :title "" :keywords nil :date ,denote-fixtures-epoch-b)
    ("signature" :title "Sequence note" :keywords ("zettel") :signature "1a2" :date ,denote-fixtures-epoch-a)
    ("signature-only" :title "" :keywords nil :signature "draft" :date ,denote-fixtures-epoch-c)
    ("signature-words" :title "Signed" :keywords ("x") :signature "Draft Two_Final" :date ,denote-fixtures-epoch-a)
    ("signature-punctuation" :title "Signed" :keywords nil :signature "A.B-C (v2)" :date ,denote-fixtures-epoch-a)
    ("title-punctuation" :title "Hello, World! (draft) #1 & more?" :keywords ("misc") :date ,denote-fixtures-epoch-a)
    ("title-quotes-backslash" :title "He said \"hi\" \\ back" :keywords nil :date ,denote-fixtures-epoch-a)
    ("title-unicode-accents" :title "Café Über straße" :keywords ("français") :date ,denote-fixtures-epoch-c)
    ("title-cjk" :title "日本語 ノート" :keywords ("日本") :date ,denote-fixtures-epoch-c)
    ("title-smart-quotes-dash" :title "‘Smart’ “quotes” — and dashes" :keywords nil :date ,denote-fixtures-epoch-c)
    ("title-multiple-spaces" :title "  lots   of   space  " :keywords nil :date ,denote-fixtures-epoch-a)
    ("title-separators" :title "foo_bar=baz--qux" :keywords nil :date ,denote-fixtures-epoch-a)
    ("title-dots" :title "v1.2.3 release notes" :keywords ("release") :date ,denote-fixtures-epoch-b)
    ("title-uppercase" :title "UPPER lower MiXeD" :keywords ("CAPS") :date ,denote-fixtures-epoch-b)
    ("title-angle-brackets" :title "a<b>c" :keywords nil :date ,denote-fixtures-epoch-b)
    ("keywords-sorted" :title "Sorting" :keywords ("zeta" "alpha" "mu") :date ,denote-fixtures-epoch-a)
    ("keywords-sluggified" :title "Slugs" :keywords ("foo bar" "baz-qux" "a_b" "x=y" "dot.ted") :date ,denote-fixtures-epoch-a)
    ("keywords-mixed-case-sort" :title "Case sort" :keywords ("Zeta" "alpha") :date ,denote-fixtures-epoch-a)
    ("keywords-duplicates" :title "Dups" :keywords ("same" "same") :date ,denote-fixtures-epoch-a)
    ("everything" :title "The Full Monty" :keywords ("b" "a") :signature "9z" :date ,denote-fixtures-epoch-c))
  "Inputs for `denote' (one note per file type each).")

(defconst denote-fixtures-order-cases
  `(("order-default"
     :order (identifier signature title keywords) :always-at nil
     :title "Order test" :keywords ("k1" "k2") :signature "s1" :date ,denote-fixtures-epoch-a)
    ("order-title-first"
     :order (title keywords signature identifier) :always-at nil
     :title "Order test" :keywords ("k1" "k2") :signature "s1" :date ,denote-fixtures-epoch-a)
    ("order-signature-first"
     :order (signature title keywords identifier) :always-at nil
     :title "Order test" :keywords ("k1") :signature "s1" :date ,denote-fixtures-epoch-a)
    ("order-keywords-first"
     :order (keywords identifier title signature) :always-at nil
     :title "Order test" :keywords ("k1") :signature nil :date ,denote-fixtures-epoch-a)
    ("order-partial-list"
     :order (title keywords) :always-at nil
     :title "Partial order" :keywords ("k1") :signature "s1" :date ,denote-fixtures-epoch-a)
    ("order-identifier-last-no-title"
     :order (title signature keywords identifier) :always-at nil
     :title "" :keywords ("k1") :signature nil :date ,denote-fixtures-epoch-a)
    ("delimiter-always-present"
     :order (identifier signature title keywords) :always-at t
     :title "Always at" :keywords ("k1") :signature nil :date ,denote-fixtures-epoch-a)
    ("delimiter-always-present-reordered"
     :order (title identifier keywords signature) :always-at t
     :title "Always at" :keywords ("k1") :signature "s" :date ,denote-fixtures-epoch-a))
  "Inputs for `denote-file-name-components-order' variants (markdown-yaml).")

(defconst denote-fixtures-slug-cases
  '("Hello World"
    "  leading and trailing  "
    "multiple    inner   spaces"
    "UPPER Case"
    "Hello, World! (draft) #1 & more?"
    "foo_bar"
    "foo=bar"
    "foo-bar"
    "foo--bar__baz==qux"
    "a.b.c"
    "Café Über straße"
    "ÀÉÎÕÜ"
    "日本語 ノート"
    "‘single’ “double”"
    "em — dash"
    "price: $5 / 50% off"
    "back\\slash"
    "a<b>c"
    "tab\tseparated"
    "@at@sign@"
    "trailing_"
    "-leading-hyphen")
  "Strings passed through each of the title/signature/keyword sluggifiers.")

(defconst denote-fixtures-link-cases
  `(("plain" :title "Linked note" :keywords ("a") :signature nil :description "Custom text")
    ("with-signature" :title "Linked note" :keywords nil :signature "1b" :description "Sig desc")
    ("unicode-description" :title "Café" :keywords nil :signature nil :description "Ünïcödé — desc"))
  "Notes to link to.")

(defconst denote-fixtures-parse-cases
  '("20240305T140709--hello-world__emacs_neovim.org"
    "20240305T140709--hello-world.md"
    "20240305T140709__emacs.txt"
    "20240305T140709.org"
    "20240305T140709==1a2--sequence-note__zettel.org"
    "20240305T140709==1a2.md"
    "--order-test__k1_k2==s1@@20240305T140709.md"
    "==s1--order-test__k1@@20240305T140709.md"
    "__k1@@20240305T140709--order-test.md"
    "@@20240305T140709--always-at__k1.md"
    "20240305T140709--encrypted__secret.org.gpg"
    "/some/dir/20240305T140709--with-dir__kw.md"
    "20240305T140709--title-with--double-hyphen__kw.md"
    "not-a-denote-file.md"
    "@@custom-id--free-form-identifier.md")
  "File names given to `denote-retrieve-filename-*'.")

;;;; Generators

(defun denote-fixtures-notes ()
  (mapcar
   (lambda (case)
     (let* ((name (car case))
            (input (cdr case)))
       `(("name" . ,name)
         ("input" . ,(denote-fixtures--input-json input))
         ("outputs" .
          ,(mapcar (lambda (ft)
                     (let ((res (denote-fixtures--create input ft)))
                       `(,(symbol-name ft)
                         ("filename" . ,(car res))
                         ("contents" . ,(cdr res)))))
                   denote-fixtures-file-types)))))
   denote-fixtures-note-cases))

(defun denote-fixtures-orders ()
  (mapcar
   (lambda (case)
     (let* ((name (car case))
            (input (cdr case))
            (denote-file-name-components-order (plist-get input :order))
            (denote-identifier-delimiter-always-present-in-file-name (plist-get input :always-at))
            (res (denote-fixtures--create input 'markdown-yaml)))
       `(("name" . ,name)
         ("input" . ,(denote-fixtures--input-json input))
         ("file_name_components_order" . ,(denote-fixtures--vec (mapcar #'symbol-name (plist-get input :order))))
         ("identifier_delimiter_always_present" . ,(denote-fixtures--bool (plist-get input :always-at)))
         ("filename" . ,(car res))
         ;; Parsing the file name back must work whatever the order.
         ("parsed" .
          (("identifier" . ,(denote-retrieve-filename-identifier (car res)))
           ("title" . ,(denote-retrieve-filename-title (car res)))
           ("signature" . ,(denote-retrieve-filename-signature (car res)))
           ("keywords" . ,(denote-retrieve-filename-keywords (car res))))))))
   denote-fixtures-order-cases))

(defun denote-fixtures-slugs ()
  (mapcar
   (lambda (str)
     `(("input" . ,str)
       ("title" . ,(denote-sluggify-and-apply-rules 'title str))
       ("signature" . ,(denote-sluggify-and-apply-rules 'signature str))
       ("keyword" . ,(denote-sluggify-and-apply-rules 'keyword str))))
   denote-fixtures-slug-cases))

(defun denote-fixtures-links ()
  (mapcar
   (lambda (case)
     (let ((name (car case))
           (input (append (cdr case) (list :date denote-fixtures-epoch-a))))
       `(("name" . ,name)
         ("input" . ,(append (denote-fixtures--input-json input)
                             `(("description" . ,(plist-get input :description)))))
         ("outputs" .
          ,(mapcar
            (lambda (ft)
              (denote-fixtures--with-denote-dir dir
                (let* ((path (denote (plist-get input :title) (plist-get input :keywords) ft dir
                                     (plist-get input :date) nil (plist-get input :signature) nil))
                       (desc (plist-get input :description))
                       (default-desc (denote-get-link-description path ft)))
                  `(,(symbol-name ft)
                    ("filename" . ,(file-name-nondirectory path))
                    ("contents" . ,(denote-fixtures--read-file path))
                    ("default_description" . ,default-desc)
                    ("link_with_description" . ,(denote-format-link path desc ft nil))
                    ("link_default_description" . ,(denote-format-link path default-desc ft nil))
                    ("link_empty_description" . ,(denote-format-link path "" ft nil))
                    ("link_id_only" . ,(denote-format-link path desc ft t))))))
            denote-fixtures-file-types)))))
   denote-fixtures-link-cases))

(defun denote-fixtures-parses ()
  (mapcar
   (lambda (file)
     `(("filename" . ,file)
       ("identifier" . ,(denote-retrieve-filename-identifier file))
       ("title" . ,(denote-retrieve-filename-title file))
       ("signature" . ,(denote-retrieve-filename-signature file))
       ("keywords" . ,(denote-retrieve-filename-keywords file))))
   denote-fixtures-parse-cases))

;;;; Main

(defun denote-fixtures-generate ()
  (let* ((data `(("generator" . "scripts/emacs-fixtures/generate.el")
                 ("denote_version" . ,(denote-fixtures-version))
                 ("tz" . ,denote-fixtures-tz)
                 ("notes" . ,(vconcat (denote-fixtures-notes)))
                 ("orders" . ,(vconcat (denote-fixtures-orders)))
                 ("slugs" . ,(vconcat (denote-fixtures-slugs)))
                 ("links" . ,(vconcat (denote-fixtures-links)))
                 ("parse" . ,(vconcat (denote-fixtures-parses)))))
         (json-encoding-pretty-print t)
         (json-encoding-default-indentation "  ")
         (text (json-encode data)))
    (make-directory (file-name-directory denote-fixtures-output) t)
    (with-temp-file denote-fixtures-output
      (setq buffer-file-coding-system 'utf-8-unix)
      (insert text "\n"))
    (message "Wrote %s (Denote %s): %d notes, %d orders, %d slugs, %d links, %d parse cases"
             (file-relative-name denote-fixtures-output denote-fixtures-root)
             (denote-fixtures-version)
             (length denote-fixtures-note-cases)
             (length denote-fixtures-order-cases)
             (length denote-fixtures-slug-cases)
             (length denote-fixtures-link-cases)
             (length denote-fixtures-parse-cases))))

(denote-fixtures-generate)

;;; generate.el ends here
