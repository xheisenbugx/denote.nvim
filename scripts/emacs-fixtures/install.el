;;; install.el --- Hermetically install Denote from GNU ELPA -*- lexical-binding: t -*-

;; Installs Denote into a throwaway package directory (never ~/.emacs.d).
;; The directory defaults to `.cache/emacs-fixtures/elpa' at the repository root
;; and can be overridden with the DENOTE_FIXTURES_ELPA environment variable.

(require 'package)

(defvar denote-fixtures-root
  (expand-file-name "../.." (file-name-directory (or load-file-name buffer-file-name))))

(setq package-user-dir
      (or (getenv "DENOTE_FIXTURES_ELPA")
          (expand-file-name ".cache/emacs-fixtures/elpa" denote-fixtures-root)))
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")))
(setq package-check-signature nil)
(package-initialize)
(unless (package-installed-p 'denote)
  (package-refresh-contents)
  (package-install 'denote))
(require 'denote)

(provide 'denote-fixtures-install)
;;; install.el ends here
