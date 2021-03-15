;;; hermes.el --- A Mercurial frontend               -*- lexical-binding: t; -*-

;; Copyright (C) 2021

;; Author:  <jaeyoon@localhost>
;; Keywords: vc

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'ewoc)

(require 'aio)
(require 'transient)
(require 'with-editor)

(add-to-list 'auto-mode-alist
             (cons (rx (or string-start "/")
                       "hg-editor-" (+ (any alphanumeric "-_")) ".commit.hg.txt"
                       string-end)
                   #'with-editor-mode))

(defvar hermes--log-revset "reverse(.~3::)")
(defvar hermes--hg-commands '("hg" "--color=never" "--pager=never"))
(defvar hermes--log-template
  (concat "changeset: {node|short}\\n"
          "summary: {desc|firstline}\\n"
          "date: {date|isodate}\\n"
          "{parents % \"parent: {node|short}\\n\"}"
          "{tags % \"tag: {tag}\\n\"}"))

(defclass hermes--base ()
  ((parent      :initarg :parent      :initform nil)
   (expanded    :initarg :expanded    :initform nil)))
(defclass hermes--changeset (hermes--base)
  ((title       :initarg :title       :initform nil)
   (rev         :initarg :rev         :initform nil)
   (current     :initarg :current     :initform nil)
   (tags        :initarg :tags)
   (summary     :initarg :summary)
   (props       :initarg :props)
   (files       :initarg :files       :initform nil)
   (parent-revs :initarg :parent-revs :initform nil)
   (child-revs  :initarg :child-revs  :initform nil)))
(defclass hermes--file (hermes--base)
  ((file        :initarg :file)
   (rev         :initarg :rev)
   (status      :initarg :status)
   (hunks       :initarg :hunks       :initform nil)))
(defclass hermes--hunk (hermes--base)
  ((lines       :initarg :lines)))

(defclass hermes--shelve (hermes--base)
  ((name        :initarg :name)
   (when        :initarg :when)
   (message     :initarg :message)
   (files       :initarg :files       :initform nil)))

;; generic methods
(cl-defgeneric hermes--print (data))
(cl-defmethod hermes--print ((data hermes--changeset))
  (let ((faces (and (oref data current) (list 'bold))))
    (if (oref data title)
        (insert (hermes--indent data)
                (propertize (oref data title) 'face 'bold))
      (insert (hermes--indent data t)
              (propertize (oref data rev)
                          'face (cons 'font-lock-type-face faces))
              " "
              (mapconcat (lambda (tag)
                           (propertize tag
                                       'face (cons 'font-lock-keyword-face faces)))
                         (oref data tags)
                         " "))
      (let* ((date (cadr (assq 'date (oref data props))))
             (padding (and date
                           (- (window-width)
                              (current-column)
                              (length date)
                              1))))
        (when (and date (> padding 0))
          (insert (make-string padding ?\s)
                  (propertize date 'face 'font-lock-doc-face))))
      (insert "\n"
              (hermes--indent data)
              (propertize (oref data summary) 'face (cons 'italic faces))))))
(cl-defmethod hermes--print ((data hermes--file))
  (insert (hermes--indent data)
          "  " (propertize (oref data status) 'face 'font-lock-keyword-face) " "
          (oref data file)))
(cl-defmethod hermes--print ((data hermes--hunk))
  (let* ((hunk-header (car (oref data lines)))
         (line-num (and (string-match
                         "@@ -[0-9]+,[0-9]+ [+]\\([0-9]+\\),"
                         hunk-header)
                        (string-to-number (match-string 1 hunk-header)))))
    (dolist (line (oref data lines))
      (let ((face (cond ((string-match "^=" line)
                         'bold)
                        ((string-match "^-" line)
                         'diff-removed)
                        ((string-match "^[+]" line)
                         'diff-added)
                        (t
                         'diff-context))))
        (insert (propertize line 'face face))
        (when line-num
          (put-text-property (point-at-bol) (point-at-eol)
                             'hermes-line-num line-num)
          (unless (member (char-after (point-at-bol)) '(?- ?@))
            (cl-incf line-num)))
        (insert "\n")))))
(cl-defmethod hermes--print ((data hermes--shelve))
  (insert (propertize (format "%-20.20s" (oref data name)) 'face 'font-lock-keyword-face)
          (propertize (format "%-10.10s" (oref data when)) 'face 'font-lock-comment-face)
          (propertize (oref data message) 'face 'italic)))

(cl-defgeneric hermes--item-string (data))
(cl-defmethod hermes--item-string ((data hermes--changeset))
  (oref data rev))
(cl-defmethod hermes--item-string ((data hermes--shelve))
  (oref data name))
(cl-defmethod hermes--item-string ((data t))
  (oref data file))

(cl-defgeneric hermes--expandable (data))
(cl-defmethod hermes--expandable ((data hermes--hunk))
  nil)
(cl-defmethod hermes--expandable ((data t))
  t)

(cl-defgeneric hermes--expand (data) node &optional force)
(cl-defmethod hermes--expand ((data hermes--changeset) node &optional force)
  (if (and (oref data files) (not force))
      (dolist (f (oref data files))
        (ewoc-enter-after hermes--ewoc node f))
    (hermes--with-command-output "Showing revision"
      `(,@hermes--hg-commands "status" "--change" ,(oref data rev))
      (lambda (o)
        (hermes--parse-status-files data o (oref data rev))
        (hermes--expand data node)))))
(cl-defmethod hermes--expand ((data hermes--file) node &optional force)
  (if (and (oref data hunks) (not force))
      (hermes--show-file-hunks node data)
    (hermes--with-command-output "Expanding file"
      `( ,@hermes--hg-commands "diff"
         ,@(append (and (oref data rev)
                        (list "--change" (oref data rev)))
                   (list (oref data file))))
      (lambda (o)
        (setf (oref data hunks)
              (mapcar (lambda (hunk)
                        (hermes--hunk
                         :lines (split-string (concat "@@" hunk) "\n")
                         :parent data))
                      (cdr (split-string o "\n@@" t))))
        (hermes--expand data node)))))
(cl-defmethod hermes--expand ((data hermes--shelve) node &optional force)
  (if (and (oref data files) (not force))
      (dolist (file (oref data files))
        (ewoc-enter-after hermes--ewoc node file))
    (hermes--with-command-output "Expanding shelve"
      `(,@hermes--hg-commands "shelve" "-p" ,(oref data name))
      (lambda (o)
        (setf (oref data files)
              (mapcar (lambda (f)
                        (let* ((hunks (split-string f "\n@@" t))
                               (file-line (car (split-string (pop hunks) "\n")))
                               (filename (and (string-match " [ab]/\\([^ \\n]+\\)" file-line)
                                              (match-string 1 file-line)))
                               (file (hermes--file :file filename
                                                   :rev nil
                                                   :status "M"
                                                   :parent data)))
                          (setf (oref file hunks)
                                (mapcar (lambda (hunk)
                                          (hermes--hunk
                                           :lines (split-string (concat "@@" hunk) "\n")
                                           :parent file))
                                        hunks))
                          file))
                      (cdr (split-string o "\ndiff --git" t))))
        (hermes--expand data node)))))

(cl-defgeneric hermes--visit (data))
(cl-defmethod hermes--visit ((data hermes--changeset))
  (hermes--with-command-output (format "Updating to %s" (oref data rev))
    `(,@hermes--hg-commands "update" "--rev" ,(oref data rev))
    #'hermes-refresh))
(cl-defmethod hermes--visit ((data hermes--file))
  (funcall (if current-prefix-arg
               #'find-file-other-window
             #'find-file)
           (oref data file)))
(cl-defmethod hermes--visit ((data hermes--hunk))
  (let ((line-num (get-text-property (point) 'hermes-line-num)))
    (with-current-buffer
        (funcall (if current-prefix-arg
                     #'find-file-other-window
                   #'find-file)
                 (oref (oref data parent) file))
      (when line-num
        (goto-line line-num)))))
(cl-defmethod hermes--visit ((data hermes--shelve))
  (hermes--with-command-output (format "Unshelve %s" (oref data name))
    `(,@hermes--hg-commands
      "unshelve"
      ,@(when current-prefix-arg (list "--keep"))
      "-n"
      ,(oref data name))
    #'hermes-refresh))

(cl-defgeneric hermes--revert (data))
(cl-defmethod hermes--revert ((data hermes--changeset))
  (when (and (oref data rev) (y-or-n-p (format "Strip changeset %s? " (oref data rev))))
    (hermes--with-command-output (format "Stripping changeset %s..." (oref data rev))
      `( ,@hermes--hg-commands
         "strip" "--rev" ,(oref data rev))
      #'hermes-refresh))
  (when (and (null (oref data rev)) (y-or-n-p "Revert pending changes? "))
    (hermes--with-command-output "Revert pending changes..."
      `((,@hermes--hg-commands "update" "-C" ".")
        ("rm" "-f" ,@(mapcar (lambda (d) (oref d file))
                             (remove-if-not (lambda (d) (string= "?" (oref d status)))
                                            (oref data files)))))
      #'hermes-refresh)))
(cl-defmethod hermes--revert ((data hermes--file))
  (when (y-or-n-p (format "Revert %s? " (oref data file)))
    (let ((parent (oref data parent)))
      (hermes--with-command-output "Reverting file"
        `( ,@hermes--hg-commands
           "revert"
           ,@(and (null (oref parent title))
                  (list "--rev"
                        (oref parent rev)))
           "--"
           ,(oref data file))
        #'hermes-refresh))))
(cl-defmethod hermes--revert ((data hermes--hunk))
  (when (y-or-n-p "Revert hunk? ")
    (let ((parent (oref data parent))
          (temp-file (make-nearby-temp-file "hunk" nil ".patch")))
      (write-region
       (mapconcat #'identity
                  (append (oref parent preamble)
                          (oref data lines)
                          '(""))
                  "\n")
       nil temp-file)
      (hermes--with-command-output "Reverting hunk"
        `("patch" "--unified" "--reverse" "--batch" "--input" ,temp-file "--"
          ,(oref data file))
        (lambda (_)
          (delete-file temp-file)
          (hermes-refresh))))))
(cl-defmethod hermes--revert ((data hermes--shelve))
  (when (y-or-n-p (format "Delete %s? " (oref data name)))
    (hermes--with-command-output (format "Deleting shelve %s" (oref data name))
      `(,@hermes--hg-commands "shelve" "-d" ,(oref data name))
      #'hermes-refresh)))

;; process invocation
(defun aio-start-file-process (command &rest args)
  (let* ((buf (generate-new-buffer (format " *aio[%s-%s]*" command args)))
         (proc (apply #'start-file-process command buf command args))
         (promise (aio-promise)))
    (prog1 promise
      (setf (process-sentinel proc)
            (lambda (proc event)
              (when (memq (process-status proc) '(exit signal))
                (let ((s (with-current-buffer buf (prog1 (buffer-string) (kill-buffer buf)))))
                  (aio-resolve promise (lambda () s)))))))))
(defun hermes--with-command-output (name command-and-args callback)
  "Run command(s) and feed the output to callback.
If more multiple commands are given, runs them in parallel."
  (declare (indent 1))
  (let* ((reporter (and name (make-progress-reporter name)))
         (d default-directory))
    (aio-with-async
      (let ((default-directory d))
        (funcall callback
                 (if (not (listp (car command-and-args)))
                     (aio-await (apply #'aio-start-file-process command-and-args))
                   (cl-loop for p in (mapcar (lambda (c) (apply #'aio-start-file-process c))
                                             command-and-args)
                            collect (aio-await p)))))
      (when reporter
        (progress-reporter-done reporter)))))

(defun hermes--term-sentinel (proc event)
  (when (memq (process-status proc) '(exit signal))
    (let ((buffer (process-buffer proc))
          (callback (process-get proc 'hermes--process-callback))
          (reporter (process-get proc 'hermes--reporter)))
      (when (equal "finished\n" event)
        (kill-buffer buffer))
      (when callback (funcall callback buffer))
      (when reporter
        (progress-reporter-done reporter)))))
(advice-add #'term-sentinel :after 'hermes--term-sentinel)

(defun hermes--convert-to-remote-terminal-commands (command-and-args)
  (if (tramp-tramp-file-p default-directory)
      (let ((v (tramp-dissect-file-name default-directory)))
        (append `("ssh"
                  ,@(when tramp-ssh-controlmaster-options
                      (split-string tramp-ssh-controlmaster-options nil t))
                  "-t"
                  ,@(when (tramp-file-name-user v)
                      (list "-l" (tramp-file-name-user v)))
                  (tramp-file-name-host-port v)
                  "--")
                command-and-args))
    command-and-args))

(defun hermes--run-interactive-commands (name command-and-args &optional callback require-terminal show)
  "Run a command and call callback with the buffer after it is done."
  (declare (indent 1))
  (with-editor
    (let* ((reporter (and name (make-progress-reporter name)))
           (buffer-name (generate-new-buffer-name (format "*hermes-command[%s]*" name)))
           (buffer (if require-terminal
                       (progn
                         (setq command-and-args (hermes--convert-to-remote-terminal-commands command-and-args))
                         (apply #'term-ansi-make-term
                                buffer-name
                                (car command-and-args)
                                nil
                                (cdr command-and-args)))
                     (process-buffer (apply #'start-file-process
                                            name
                                            buffer-name
                                            command-and-args))))
           proc)
      (setq proc (get-buffer-process buffer))
      (if require-terminal
          (with-current-buffer buffer
            (term-mode)
            (term-char-mode))
        (set-process-sentinel proc #'hermes--term-sentinel))
      (process-put proc 'hermes--process-callback callback)
      (process-put proc 'hermes--reporter reporter)
      (when show
        (display-buffer buffer)))))

;; printers
(defvar hermes--ewoc nil)
(defun hermes--filter-children (data)
  (let ((deleted (list data)))
    (ewoc-filter hermes--ewoc
                 (lambda (d)
                   (not (and d
                             (memq (oref d parent) deleted)
                             (or (setf (oref d expanded) nil)
                                 (push d deleted))))))))

(defun hermes--indent (r &optional for-changeset-header)
  (let ((i 0)
        (changeset (pcase (type-of r)
                     ('hermes--file (oref r parent))
                     ('hermes--changeset r)
                     (_ nil))))
    (cond ((null changeset)
           "")
          ((hermes--shelve-p changeset)
           "   ")
          ((oref changeset title)
           "   ")
          (t
           (cdr (assq (cond (for-changeset-header 'indent1)
                            ((eq r changeset)     'indent2)
                            (t                    'indent3))
                      (oref changeset props)))))))

(defun hermes-printer (data)
  (if (null data)
      (insert "\n" (make-string (1- (window-width)) ?-))
    (hermes--print data)))

;; parsers
(defun hermes--parse-changesets (o)
  "Parse 'hg log' output into hermes--changeset records."
  ;; --debug option may print out some garbage at the beginnig.
  (when-let (p (string-match "\n.\s+changeset: " o))
    (setq o (substring o (1+ p))))
  (let (changesets props)
    (dolist (line (split-string o "\n" t))
      ;; 'o' can be used for graphic representation
      (when (string-match "^\\([^a-np-z]+\\)\\([a-z]+\\): +\\(.*\\)" line)
        (let* ((indent (match-string 1 line))
               (k (intern (match-string 2 line)))
               (v (match-string 3 line))
               p)
          (when (and (eq k 'changeset)
                     props)
            (push (hermes--changeset :rev (cadr (assq 'changeset props))
                                     :summary (cadr (assq 'summary props))
                                     :tags (cdr (assq 'tag props))
                                     :props (nreverse props))
                  changesets)
            (setq props nil))
          (push (cons (cond ((eq k 'changeset) 'indent1)
                            ((eq k 'summary)   'indent2)
                            (t                 'indent3))
                      indent)
                props)
          (when (memq k '(changeset parent))
            (setq v (car (nreverse (split-string v ":"))))
            (when (string-match "^0+$" v)
              (setq v nil)))
          (when v
            (if (setq p (assq k props))
                (push v (cdr p))
              (push (cons k (list v)) props))))))
    (when props
      (push (hermes--changeset :rev (cadr (assq 'changeset props))
                               :summary (cadr (assq 'summary props))
                               :tags (cdr (assq 'tag props))
                               :props (nreverse props))
            changesets)
      (setq props nil))
    (hermes--construct-hierarchy (nreverse changesets))))

(defun hermes--construct-hierarchy (changesets)
  (let (trees)
    (dolist (c changesets)
      (push (cons (oref c rev) c) trees))
    (dolist (c changesets)
      (dolist (parent (cdr (assq 'parent (oref c props))))
        (when (and parent (setq parent (cdr (assoc parent trees))))
          (push parent (oref c parent-revs))
          (push c (oref parent child-revs)))))
    (dolist (c changesets)
      (cl-callf nreverse (oref c parent-revs))
      (cl-callf nreverse (oref c child-revs))))
  changesets)

(defun hermes--parse-status-files (parent o &optional rev)
  (setf (oref parent files)
        (mapcar (lambda (line)
                  (hermes--file :file (substring line 2)
                                :rev rev
                                :status (substring line 0 1)
                                :parent parent))
                (split-string (ansi-color-filter-apply o) "\n" t))))

(defun hermes--parse-shelves (o)
  (remove nil (mapcar (lambda (line)
                        (when (string-match "^\\([^ (]+\\) *\\([^)]+)\\) *\\(.*$\\)" line)
                          (hermes--shelve :name (match-string 1 line)
                                          :when (match-string 2 line)
                                          :message (match-string 3 line))))
                      (split-string o "\n" t))))

;; commands
(defun hermes-goto-next (arg)
  "Move to next node."
  (interactive "p")
  (ewoc-goto-next hermes--ewoc arg))

(defun hermes-goto-prev (arg)
  "Move to previous node."
  (interactive "p")
  (ewoc-goto-prev hermes--ewoc arg))

(defun hermes-goto-up-level ()
  "Move to parent node."
  (interactive)
  (let* ((starting-pos (point))
         (node (ewoc-locate hermes--ewoc))
         (data (and node (ewoc-data node)))
         (parent (and node (oref data parent)))
         old-node)
    (setq old-node node
          node (ewoc-goto-prev hermes--ewoc 1))
    (when (eq old-node node)
      (setq node nil))
    (while (not (or (eq old-node node)
                    (eq parent (ewoc-data node))))
      (setq old-node node
            node (ewoc-goto-prev hermes--ewoc 1)))
    (when (eq old-node node)
      (goto-char starting-pos)
      (error "No parent node found."))))

(defun hermes-goto-down-level ()
  "Move to first child node."
  (interactive)
  (let* ((starting-pos (point))
         (node (ewoc-locate hermes--ewoc))
         (data (and node (ewoc-data node))))
    (setq node (ewoc-goto-next hermes--ewoc 1))
    (unless (and node
                 (ewoc-data node)
                 (eq data
                     (oref (ewoc-data node) parent)))
      (goto-char starting-pos)
      (error "No child node found."))))

(defun hermes-goto-same-level-aux (move-fn arg)
  (let* ((starting-pos (point))
         (node (ewoc-locate hermes--ewoc))
         (data (and node (ewoc-data node)))
         (parent (and data (oref data parent)))
         old-node)
    (while (and node (>= (cl-decf arg) 0))
      (setq old-node node
            node (funcall move-fn hermes--ewoc 1))
      (when (eq old-node node)
        (setq node nil))
      (while (and node
                  (setq data (ewoc-data node))
                  (not (eq parent (oref data parent))))
        (setq old-node node
              node (funcall move-fn hermes--ewoc 1))
        (when (eq old-node node)
          (setq node nil))))
    (unless node
      (goto-char starting-pos)
      (error "No more node at the same level."))))

(defun hermes-goto-next-same-level (arg)
  "Move to next node at the same level."
  (interactive "p")
  (hermes-goto-same-level-aux #'ewoc-goto-next arg))

(defun hermes-goto-prev-same-level (arg)
  "Move to previous node at the same level."
  (interactive "p")
  (hermes-goto-same-level-aux #'ewoc-goto-prev arg))

(defun hermes--show-file-hunks (node file)
  (dolist (hunk (oref file hunks))
    (setq node (ewoc-enter-after hermes--ewoc node hunk))))

(defun hermes-toggle-expand ()
  "Expand or shrink current node.
When a prefix argument is given while expanding, recompute childrens."
  (interactive)
  (setq buffer-read-only nil)
  (let* ((node (ewoc-locate hermes--ewoc))
         (data (and node (ewoc-data node)))
         buffer-read-only)
    (when (and data (hermes--expandable data))
      (if (cl-callf not (oref data expanded))
          (hermes--expand data node current-prefix-arg)
        (hermes--filter-children data)))))

(defun hermes--current-data ()
  (when-let (node (ewoc-locate hermes--ewoc))
    (ewoc-data node)))

(defun hermes--current-rev-or-error ()
  (let ((data (hermes--current-data)))
    (while (and data (not (eq (type-of data) 'hermes--changeset)))
      (setq data (oref data parent)))
    (unless data
      (error "Not on a changeset."))
    (oref data rev)))

(defun hermes-visit ()
  "Do appropriate actions on the current node.
Changeset - update to the revision.
File - opens the file. With prefix argument, opens it on other window."
  (interactive)
  (hermes--visit (hermes--current-data)))

(defun hermes-shelve (message)
  "Create shelve.
With prefix argument, keep changes in the working directory."
  (interactive "sShelve message: ")
  (hermes--with-command-output "shelve"
    `( ,@hermes--hg-commands "shelve"
       ,@(when current-prefix-arg (list "-k")) "-m" ,message)
    #'hermes-refresh))

(defun hermes-kill ()
  "Kill current node into the kill ring.
Changeset - revision hash.
Others - filename."
  (interactive)
  (let (buffer-read-only)
    (when-let (data (hermes--current-data))
      (message "Copied %s "
               (kill-new (hermes--item-string data))))))

(defun hermes-revert ()
  "Revert changes under the point."
  (interactive)
  (hermes--revert (hermes--current-data)))

(defvar hermes-run-hg-history nil)
(defun hermes-run-hg (command)
  "Run arbitrary hg command."
  (interactive "sRun: hg ")
  (hermes--run-interactive-commands (car (split-string command nil t))
    `("bash" "-c" ,(concat (mapconcat #'identity hermes--hg-commands " ") command))
    nil nil t))

(transient-define-prefix hermes-commit ()
  "Create a new commit or replace an existing commit."
  ["Arguments"
   ("-A" "mark new/missing files as added/removed" ("-A" "--addremove"))
   ("-e" "prompt to edit the commit message"       ("-e" "--edit"))
   ("-s" "use the secret phase for committing"     ("-s" "--secret"))
   ("-n" "do not keep empty commit after uncommit" ("-n" "--no-keep"))
   ("-i" "use interactive mode"                    ("-i" "--interactive"))]
  [["Create"
    ("c" "Commit"    hermes-commit-commit)
    ("d" "Duplicate" hermes-commit-duplicate)
    ("u" "Uncommit"  hermes-commit-uncommit)]
   ["Edit HEAD"
    ("a" "Amend"     hermes-commit-amend)]])
(defun hermes-commit-duplicate ()
  "Create a duplicate change."
  (interactive)
  (hermes--with-command-output (format "Duplicating %s" (hermes--current-rev-or-error))
    `(,@hermes--hg-commands
      "graft" "-f" "-r" ,(hermes--current-rev-or-error))
    #'hermes-refresh))
(defun hermes-commit-uncommit (&optional args)
  "Create a duplicate change."
  (interactive (list (transient-args 'hermes-commit)))
  (hermes--with-command-output "Uncommitting"
    `(,@hermes--hg-commands
      "uncommit" "--allow-dirty-working-copy" ,@args)
    #'hermes-refresh))
(cl-macrolet ((def (&rest cmds)
                   (let (form)
                     (dolist (cmd cmds)
                       (push `(defun ,(intern (concat "hermes-commit-" cmd)) (&optional args)
                                ,(concat "Run hg " cmd ".")
                                (interactive (list (transient-args 'hermes-commit)))
                                (hermes--run-interactive-commands ,cmd
                                  (append hermes--hg-commands (cons ,cmd args))
                                  #'hermes-refresh
                                  (member "--interactive" args)))
                             form))
                     (cons 'progn form))))
  (def "commit" "amend"))

(transient-define-prefix hermes-phase ()
  "Set or show the current phase name."
  ["Arguments"
   ("-f" "allow to move boundary backward"         ("-f" "--force"))]
  [["Get"
    ("SPC" "get changeset phase" hermes-phase-show)]
   ["Set"
    ("p" "set changeset phase to public" hermes-phase-public)
    ("d" "set changeset phase to draft"  hermes-phase-draft)
    ("s" "set changeset phase to secret" hermes-phase-secret)]])
(defun hermes-phase-show ()
  "Show the phase of the current changeset."
  (interactive)
  (hermes--with-command-output nil
    `(,@hermes--hg-commands "phase" "-r" ,(hermes--current-rev-or-error))
    (lambda (o)
      (message "Changeset %s is in %s phase."
               (propertize (hermes--current-rev-or-error)
                           'face '('font-lock-type-face bold))
               (propertize (substring (cadr (split-string o ": " t)) 0 -1)
                           'face 'bold)))))
(cl-macrolet ((def (&rest cmds)
                   (let (form)
                     (dolist (cmd cmds)
                       (push `(defun ,(intern (concat "hermes-phase-" cmd)) (&optional args)
                                ,(concat "Run hg phase --" cmd ".")
                                (interactive (list (transient-args 'hermes-phase)))
                                (hermes--run-interactive-commands "phase"
                                  (append hermes--hg-commands
                                          (list "phase" ,(concat "--" cmd))
                                          args
                                          (list "-r" (hermes--current-rev-or-error)))))
                             form))
                     (cons 'progn form))))
  (def "public" "draft" "secret"))

;; modes
(defvar hermes-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "g" #'revert-buffer)
    (define-key map (kbd "TAB") #'hermes-toggle-expand)
    (define-key map (kbd "RET") #'hermes-visit)
    (define-key map "c" #'hermes-commit)
    (define-key map ":" #'hermes-run-hg)
    (define-key map "v" #'hermes-phase)
    (define-key map "w" #'hermes-kill)
    (define-key map "z" #'hermes-shelve)
    (define-key map "k" #'hermes-revert)
    (define-key map "n" #'hermes-goto-next)
    (define-key map "p" #'hermes-goto-prev)
    (define-key map (kbd "M-n") #'hermes-goto-next-same-level)
    (define-key map (kbd "M-p") #'hermes-goto-prev-same-level)
    (define-key map (kbd "C-M-u") #'hermes-goto-up-level)
    (define-key map (kbd "C-M-d") #'hermes-goto-down-level)
    map)
  "Keymap for `hermes-mode'.")

(define-derived-mode hermes-mode special-mode "Hermes"
  "Major mode for *hermes* buffers.

\\{hermes-mode-map}"
  (setq revert-buffer-function #'hermes-refresh)
  (setq buffer-read-only nil)
  (buffer-disable-undo)
  (erase-buffer)
  (set (make-variable-buffer-local 'hermes--ewoc)
       (ewoc-create 'hermes-printer (concat "HG repository: "
                                            (abbreviate-file-name
                                             default-directory)
                                            "\n")))
  (setq buffer-read-only t)
  (hl-line-mode 1))

(defun hermes-refresh (&rest args)
  "Refresh *hermes* buffer contents."
  (let* ((hermes-buffer (current-buffer)))
    (hermes--with-command-output "Refreshing"
      (mapcar (lambda (l) (append hermes--hg-commands l))
              `(("log" "--debug" "-G" "-T" ,hermes--log-template "-r" ,hermes--log-revset)
                ("status" "--rev" ".")
                ("status" "--change" ".")
                ("parent")
                ("shelve" "--list")))
      (lambda (o)
        (let ((recents (hermes--parse-changesets (nth 0 o)))
              (modified (hermes--changeset
                         :title "Pending changes"
                         :rev nil
                         :expanded t))
              (parents (mapcar (lambda (o) (oref o rev))
                               (hermes--parse-changesets (nth 3 o))))
              (shelves (hermes--parse-shelves (nth 4 o))))
          (hermes--parse-status-files modified (nth 1 o) nil)
          (with-current-buffer hermes-buffer
            (let (buffer-read-only)
              (ewoc-filter hermes--ewoc (lambda (n) nil))
              (when (oref modified files)
                (hermes--expand modified
                                (ewoc-enter-last hermes--ewoc modified))
                (ewoc-enter-last hermes--ewoc nil))
              (dolist (changeset recents)
                (when (cl-find (oref changeset rev) parents :test #'string=)
                  (setf (oref changeset current) t)
                  (setf (oref changeset expanded) t)
                  (hermes--parse-status-files changeset (nth 2 o) "."))
                (ewoc-enter-last hermes--ewoc changeset)
                (when (oref changeset current)
                  (hermes--expand changeset (ewoc-nth hermes--ewoc -1))))
              (when (and recents shelves)
                (ewoc-enter-last hermes--ewoc nil))
              (dolist (shelve shelves)
                (ewoc-enter-last hermes--ewoc shelve)))))))))

;;;###autoload (autoload 'hermes "hermes" nil t)
(defun hermes (&optional directory)
  "Starts a *hermes* buffer on current directory."
  (interactive
   (let ((d (vc-find-root default-directory ".hg")))
     (when (or current-prefix-arg (null d))
       (setq d (vc-find-root
                (read-directory-name "HG repository directory: ") ".hg")))
     (list d)))
  (unless (or directory
              (setq directory (vc-find-root default-directory ".hg")))
    (error "No HG repository found!"))
  (let ((default-directory directory)
        (name (car (last (split-string directory "/" t))))
        (refresh (>= (prefix-numeric-value current-prefix-arg) 16)))
    (with-current-buffer (get-buffer-create (format "*hermes[%s]*" name))
      (display-buffer (current-buffer))
      (unless (derived-mode-p 'hermes-mode)
        (setq refresh t)
        (hermes-mode))
      (when refresh
        (hermes-refresh)))))

(provide 'hermes)
;;; hermes.el ends here
