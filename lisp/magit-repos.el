;;; magit-repos.el --- listing repositories  -*- lexical-binding: t -*-

;; Copyright (C) 2010-2021  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; This library implements support for listing repositories.  This
;; includes getting a Lisp list of known repositories as well as a
;; mode for listing repositories in a buffer.

;;; Code:

(require 'magit-core)

(declare-function magit-status-setup-buffer "magit-status" (directory))

(defvar x-stretch-cursor)

;;; Options

(defcustom magit-repository-directories nil
  "List of directories that are or contain Git repositories.

Each element has the form (DIRECTORY . DEPTH).  DIRECTORY has
to be a directory or a directory file-name, a string.  DEPTH,
an integer, specifies the maximum depth to look for Git
repositories.  If it is 0, then only add DIRECTORY itself.

This option controls which repositories are being listed by
`magit-list-repositories'.  It also affects `magit-status'
\(which see) in potentially surprising ways."
  :package-version '(magit . "3.0.0")
  :group 'magit-essentials
  :type '(repeat (cons directory (integer :tag "Depth"))))

(defgroup magit-repolist nil
  "List repositories in a buffer."
  :link '(info-link "(magit)Repository List")
  :group 'magit-modes)

(defcustom magit-repolist-mode-hook '(hl-line-mode)
  "Hook run after entering Magit-Repolist mode."
  :package-version '(magit . "2.9.0")
  :group 'magit-repolist
  :type 'hook
  :get 'magit-hook-custom-get
  :options '(hl-line-mode))

(defcustom magit-repolist-columns
  '(("Name"    25 magit-repolist-column-ident nil)
    ("Version" 25 magit-repolist-column-version nil)
    ("B<U"      3 magit-repolist-column-unpulled-from-upstream
     ((:right-align t)
      (:help-echo "Upstream changes not in branch")))
    ("B>U"      3 magit-repolist-column-unpushed-to-upstream
     ((:right-align t)
      (:help-echo "Local changes not in upstream")))
    ("Path"    99 magit-repolist-column-path nil))
  "List of columns displayed by `magit-list-repositories'.

Each element has the form (HEADER WIDTH FORMAT PROPS).

HEADER is the string displayed in the header.  WIDTH is the width
of the column.  FORMAT is a function that is called with one
argument, the repository identification (usually its basename),
and with `default-directory' bound to the toplevel of its working
tree.  It has to return a string to be inserted or nil.  PROPS is
an alist that supports the keys `:right-align' and `:pad-right'.
Some entries also use `:help-echo', but `tabulated-list' does not
actually support that yet."
  :package-version '(magit . "2.12.0")
  :group 'magit-repolist
  :type `(repeat (list :tag "Column"
                       (string   :tag "Header Label")
                       (integer  :tag "Column Width")
                       (function :tag "Inserter Function")
                       (repeat   :tag "Properties"
                                 (list (choice :tag "Property"
                                               (const :right-align)
                                               (const :pad-right)
                                               (symbol))
                                       (sexp   :tag "Value"))))))

(defcustom magit-repolist-column-flag-alist
  '((magit-untracked-files . "N")
    (magit-unstaged-files . "U")
    (magit-staged-files . "S"))
  "Association list of predicates and flags for `magit-repolist-column-flag'.

Each element is of the form (FUNCTION . FLAG).  Each FUNCTION is
called with no arguments, with `default-directory' bound to the
top level of a repository working tree, until one of them returns
a non-nil value.  FLAG corresponding to that function is returned
as the value of `magit-repolist-column-flag'."
  :package-version '(magit . "3.0.0")
  :group 'magit-repolist
  :type '(alist :key-type (function :tag "Predicate Function")
                :value-type (string :tag "Flag")))

;; (defcustom magit-repolist-sort-column "Path"
(defcustom magit-repolist-sort-column "Name"
 "Default sort column for function `magit-list-repositories'.
  This string should be the CAR of an entry in variable
  `magit-repolist-columns'."
  :type 'string
  :group 'magit-repolist)

(defcustom magit-repolist-styles
  '((simple .
      (("Name" 25 magit-repolist-column-ident nil)
       ("Path" 99 magit-repolist-column-path nil)))
    (versioned .
      (("Name"    25 magit-repolist-column-ident nil)
       ("Version" 25 magit-repolist-column-version nil)))
    (status .
      (("NUS ↓↑z"   7  magit-repolist-status-flags nil)
       ("Name"     25  magit-repolist-column-ident nil)
       ("b"         2  magit-repolist-column-branches ((:right-align t)))
       ("branch"   15  magit-repolist-column-branch   nil))))
  "List of display styles for function `magit-list-repositories'.
Each entry should be a CONS whose car is a symbol identifying the
style, and whose CDR is of a form suitable for variable
`magit-repolist-columns'."
  :type 'list
  :group 'magit-repolist)

(defcustom magit-repolist-desired-styles (list 'simple 'versioned 'status)
  "A list of styles to cycle through.
Each element of the list should be a CAR value of variable
`magit-repolist-styles'."
  :type '(repeat (symbol :match (lambda (w v)
                                   (memq v (mapcar 'car magit-repolist-styles)))))
  :group 'magit-repolist)

(defvar-local magit-repolist-current-style nil)

(defvar magit-repolist-status-flag-alist
  '(("N" . magit-untracked-files)
    ("U" . magit-unstaged-files)
    ("S" . magit-staged-files)
    (" " . (lambda (x) " "))
    ("↓" . magit-repolist-column-unpulled-from-upstream)
    ("↑" . magit-repolist-column-unpushed-to-upstream)
    ("z" . magit-repolist-column-stashes)))

;;; List Repositories
;;;; Command
;;;###autoload
(defun magit-list-repositories ()
  "Display a list of repositories.

Use the options `magit-repository-directories' to control which
repositories are displayed."
  (interactive)
  (if magit-repository-directories
      (with-current-buffer (get-buffer-create "*Magit Repositories*")
        (magit-repolist-mode)
        (magit-repolist-refresh)
        (tabulated-list-print)
        (switch-to-buffer (current-buffer)))
    (message "You need to customize `magit-repository-directories' %s"
             "before you can list repositories")))

(defun magit-list-repositories-next (&optional style)
  "Cycle through the repository display styles.
See variable `magit-repolist-styles' and function
`magit-list-repositories'."
  (interactive)
  (let* ((buf (unless (eq major-mode 'magit-repolist-mode)
                (get-buffer "*Magit Repositories*")))
         (next-style
           (progn (when buf (pop-to-buffer buf))
                  (or (cadr (memq magit-repolist-current-style
                                  magit-repolist-desired-styles))
                      (car  magit-repolist-desired-styles))))
         (magit-repolist-columns
           (mapcar
             (lambda (x)
               (unless (numberp (nth 1 x))
                 (condition-case err
                   (setf (nth 1 x) (eval (nth 1 x)))
                   (error (error "Malformed variable: magit-repolist-styles"))))
               x)
             (cdr (assq next-style magit-repolist-styles)))))
    (setq-local magit-repolist-current-style next-style)
    (message "magit-list-repositories: working...")
    (magit-list-repositories)
    (setq-local magit-repolist-current-style next-style)
    (message "Listing style: %s" next-style)))

;;;; Mode

(defvar magit-repolist-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "C-m") 'magit-repolist-status)
    (define-key map (kbd "n")   'magit-list-repositories-next)
    map)
  "Local keymap for Magit-Repolist mode buffers.")

(defun magit-repolist-status (&optional _button)
  "Show the status for the repository at point."
  (interactive)
  (--if-let (tabulated-list-get-id)
      (magit-status-setup-buffer (expand-file-name it))
    (user-error "There is no repository at point")))

(define-derived-mode magit-repolist-mode tabulated-list-mode "Repos"
  "Major mode for browsing a list of Git repositories."
  (setq-local x-stretch-cursor  nil)
  (setq tabulated-list-padding  0)
  (setq tabulated-list-sort-key
        (cons (or (car (assoc magit-repolist-sort-column
                              magit-repolist-columns))
                  (caar magit-repolist-columns))
              nil))
  (setq tabulated-list-format
        (vconcat (mapcar (pcase-lambda (`(,title ,width ,_fn ,props))
                           (nconc (list title width t)
                                  (-flatten props)))
                         magit-repolist-columns)))
  (tabulated-list-init-header)
  (add-hook 'tabulated-list-revert-hook 'magit-repolist-refresh nil t)
  (setq imenu-prev-index-position-function
        'magit-imenu--repolist-prev-index-position-function)
  (setq imenu-extract-index-name-function
        'magit-imenu--repolist-extract-index-name-function))

(defun magit-repolist-refresh ()
  (setq tabulated-list-entries
        (mapcar (pcase-lambda (`(,id . ,path))
                  (let ((default-directory path))
                    (list path
                          (vconcat (--map (or (funcall (nth 2 it) id) "")
                                          magit-repolist-columns)))))
                (magit-list-repos-uniquify
                 (--map (cons (file-name-nondirectory (directory-file-name it))
                              it)
                        (magit-list-repos))))))

;;;; Columns

(defun magit-repolist-column-ident (id)
  "Insert the identification of the repository.
Usually this is just its basename."
  id)

(defun magit-repolist-column-path (_id)
  "Insert the absolute path of the repository."
  (abbreviate-file-name default-directory))

(defun magit-repolist-column-version (_id)
  "Insert a description of the repository's `HEAD' revision."
  (when-let ((v (or (magit-git-string "describe" "--tags" "--dirty")
                    ;; If there are no tags, use the date in MELPA format.
                    (magit-git-string "show" "--no-patch" "--format=%cd-g%h"
                                      "--date=format:%Y%m%d.%H%M"))))
    (save-match-data
      (when (string-match "-dirty\\'" v)
        (magit--put-face (1+ (match-beginning 0)) (length v) 'error v))
      (if (and v (string-match "\\`[0-9]" v))
          (concat " " v)
        v))))

(defun magit-repolist-column-branch (_id)
  "Insert the current branch."
  (magit-get-current-branch))

(defun magit-repolist-column-upstream (_id)
  "Insert the upstream branch of the current branch."
  (magit-get-upstream-branch))

(defun magit-repolist-column-flag (_id)
  "Insert a flag as specified by `magit-repolist-column-flag-alist'.

By default this indicates whether there are uncommitted changes.
- N if there is at least one untracked file.
- U if there is at least one unstaged file.
- S if there is at least one staged file.
Only one letter is shown, the first that applies."
  (seq-some (pcase-lambda (`(,fun . ,flag))
              (and (funcall fun) flag))
            magit-repolist-column-flag-alist))

(defun magit-repolist-column-flags (id)
  "Insert all flags as specified by `magit-repolist-column-flag-alist'.
This is an alternative to function `magit-repolist-column-flag',
which only lists the first one found."
  (mapconcat
    (lambda (x) (if (apply (car x) (list id)) (cdr x) " "))
    magit-repolist-column-flag-alist
    ""))

(defun magit-repolist-status-flags (id)
  "Insert all flags as specified by `magit-repolist-status-flag-alist'.
This is an alternative to function `magit-repolist-column-flags'."
  (mapconcat
    (lambda (x)
      (let ((result (apply (cdr x) (list id))))
        (when (listp result)
          (setq result (length result)))
        (cond
         ((not result) " ")
         ((numberp result)
           (cond ((< 9 result) "+")
                 ((< 0 result) (number-to-string result))
                 (t " ")))
         ((stringp result)
           (if (or (zerop (length result))
                   (string= "0" result))
             " "
            (substring-no-properties result -1))))))
    magit-repolist-status-flag-alist
    ""))

(defun magit-repolist-column-unpulled-from-upstream (_id)
  "Insert number of upstream commits not in the current branch."
  (--when-let (magit-get-upstream-branch)
    (let ((n (cadr (magit-rev-diff-count "HEAD" it))))
      (magit--propertize-face
       (number-to-string n) (if (> n 0) 'bold 'shadow)))))

(defun magit-repolist-column-unpulled-from-pushremote (_id)
  "Insert number of commits in the push branch but not the current branch."
  (--when-let (magit-get-push-branch nil t)
    (let ((n (cadr (magit-rev-diff-count "HEAD" it))))
      (magit--propertize-face
       (number-to-string n) (if (> n 0) 'bold 'shadow)))))

(defun magit-repolist-column-unpushed-to-upstream (_id)
  "Insert number of commits in the current branch but not its upstream."
  (--when-let (magit-get-upstream-branch)
    (let ((n (car (magit-rev-diff-count "HEAD" it))))
      (magit--propertize-face
       (number-to-string n) (if (> n 0) 'bold 'shadow)))))

(defun magit-repolist-column-unpushed-to-pushremote (_id)
  "Insert number of commits in the current branch but not its push branch."
  (--when-let (magit-get-push-branch nil t)
    (let ((n (car (magit-rev-diff-count "HEAD" it))))
      (magit--propertize-face
       (number-to-string n) (if (> n 0) 'bold 'shadow)))))

(defun magit-repolist-column-branches (_id)
  "Insert number of branches."
  (let ((n (length (magit-list-local-branches))))
    (magit--propertize-face (number-to-string n) (if (> n 1) 'bold 'shadow))))

(defun magit-repolist-column-stashes (_id)
  "Insert number of stashes."
  (let ((n (length (magit-list-stashes))))
    (magit--propertize-face (number-to-string n) (if (> n 0) 'bold 'shadow))))

;;; Read Repository

(defun magit-read-repository (&optional read-directory-name)
  "Read a Git repository in the minibuffer, with completion.

The completion choices are the basenames of top-levels of
repositories found in the directories specified by option
`magit-repository-directories'.  In case of name conflicts
the basenames are prefixed with the name of the respective
parent directories.  The returned value is the actual path
to the selected repository.

If READ-DIRECTORY-NAME is non-nil or no repositories can be
found based on the value of `magit-repository-directories',
then read an arbitrary directory using `read-directory-name'
instead."
  (if-let ((repos (and (not read-directory-name)
                       magit-repository-directories
                       (magit-repos-alist))))
      (let ((reply (magit-completing-read "Git repository" repos)))
        (file-name-as-directory
         (or (cdr (assoc reply repos))
             (if (file-directory-p reply)
                 (expand-file-name reply)
               (user-error "Not a repository or a directory: %s" reply)))))
    (file-name-as-directory
     (read-directory-name "Git repository: "
                          (or (magit-toplevel) default-directory)))))

(defun magit-list-repos ()
  (cl-mapcan (pcase-lambda (`(,dir . ,depth))
               (magit-list-repos-1 dir depth))
             magit-repository-directories))

(defun magit-list-repos-1 (directory depth)
  (cond ((file-readable-p (expand-file-name ".git" directory))
         (list (file-name-as-directory directory)))
        ((and (> depth 0) (magit-file-accessible-directory-p directory))
         (--mapcat (and (file-directory-p it)
                        (magit-list-repos-1 it (1- depth)))
                   (directory-files directory t
                                    directory-files-no-dot-files-regexp t)))))

(defun magit-list-repos-uniquify (alist)
  (let (result (dict (make-hash-table :test 'equal)))
    (dolist (a (delete-dups alist))
      (puthash (car a) (cons (cdr a) (gethash (car a) dict)) dict))
    (maphash
     (lambda (key value)
       (if (= (length value) 1)
           (push (cons key (car value)) result)
         (setq result
               (append result
                       (magit-list-repos-uniquify
                        (--map (cons (concat
                                      key "\\"
                                      (file-name-nondirectory
                                       (directory-file-name
                                        (substring it 0 (- (1+ (length key)))))))
                                     it)
                               value))))))
     dict)
    result))

(defun magit-repos-alist ()
  (magit-list-repos-uniquify
   (--map (cons (file-name-nondirectory (directory-file-name it)) it)
          (magit-list-repos))))

;;; _
(provide 'magit-repos)
;;; magit-repos.el ends here
