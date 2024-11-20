;;; org-gnosis.el --- Org Zettelkasten Note Management System  -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2025  Thanos Apollo

;; Author: Thanos Apollo <public@thanosapollo.org>
;; Keywords: extensions
;; URL: https://thanosapollo.org/projects/gnosis
;; Version: 0.0.1

;; Package-Requires: ((emacs "27.2") (emacsql "4.0.3") (compat "29.1.4.2"))

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

;; Under development

;;; Code:

(require 'cl-lib)
(require 'emacsql-sqlite)
(require 'org-element)

(defvar org-gnosis-db (emacsql-sqlite-open (locate-user-emacs-file "org-gnosis.db")))

(cl-defun org-gnosis-select (value table &optional (restrictions '1=1) (flatten nil))
  "Select VALUE from TABLE, optionally with RESTRICTIONS.

Optional argument FLATTEN, when non-nil, flattens the result."
  (let ((output (emacsql org-gnosis-db `[:select ,value :from ,table :where ,restrictions])))
    (if flatten
	(apply #'append output)
      output)))

(cl-defun org-gnosis--insert-into (table values)
  "Insert VALUES to TABLE."
  (emacsql org-gnosis-db `[:insert :into ,table :values ,values]))

(defun org-gnosis-get-current-node-title ()
  "Return the title of the current node."
  (when (derived-mode-p 'org-mode)
    (let* ((parsed-data (org-element-parse-buffer))
           (title (org-element-map parsed-data 'keyword
                    (lambda (kw)
                      (when (string-equal (org-element-property :key kw) "TITLE")
                        (org-element-property :value kw)))
                    nil t)))
      title)))

(defun org-gnosis-get-filetags (&optional parsed-data)
  "Return the filetags of the buffer's PARSED-DATA as a comma-separated string."
  (let* ((parsed-data (or parsed-data (org-element-parse-buffer)))
         (filetags (org-element-map parsed-data 'keyword
                     (lambda (kw)
                       (when (string-equal (org-element-property :key kw) "FILETAGS")
                         (org-element-property :value kw)))
                     nil t)))
    (when filetags
      (mapconcat 'identity (split-string filetags "[:\s]+" t) ","))))

(defun org-gnosis-process-node (node)
  "Process a single headline NODE and return information as a list."
  (let ((title (org-element-property :raw-value node))
        (tags (org-element-property :tags node))
        (id (org-element-property :ID node))
        (children (org-element-contents node)))
    (when title
      (list title tags id
            (org-gnosis-process-children children (1+ (org-element-property :level node)))))))

(defun org-gnosis-process-children (nodes level)
  "Recursively process NODES at a given LEVEL."
  (let (result)
    (while nodes
      (let ((current-node (car nodes))
            (current-level (org-element-property :level (car nodes))))
        (if (and current-level (= current-level level))
            (progn
              (push (org-gnosis-process-node current-node) result)
              (setq nodes (cdr nodes)))
          (setq nodes (cdr nodes)))))
    (nreverse result)))

(defun org-gnosis-get-data--nodes (&optional parsed-data)
  "Return a hierarchical list of nodes with titles, tags, and IDs from PARSED-DATA."
  (let ((parsed-data (or parsed-data (org-element-parse-buffer))))
    (org-gnosis-process-children (org-element-map parsed-data 'headline #'identity) 1)))

(defun org-gnosis-get-data--topic (&optional parsed-data)
  "Retrieve the title and ID from the current org buffer or given PARSED-DATA."
  (let* ((parsed-data (or parsed-data (org-element-parse-buffer)))
         (title (org-element-map parsed-data 'keyword
                  (lambda (kw)
                    (when (string= (org-element-property :key kw) "TITLE")
                      (org-element-property :value kw)))
                  nil t))
         (id (org-element-map parsed-data 'property-drawer
                (lambda (drawer)
                  (org-element-map (org-element-contents drawer) 'node-property
                    (lambda (prop)
                      (when (string= (org-element-property :key prop) "ID")
                        (org-element-property :value prop)))
                    nil t))
                nil t))
	 (tags (org-gnosis-get-filetags)))
    (list title tags id)))

(defun org-gnosis-get--data (file)
  "Return data for FILE.

FILE: File path"
  (let* ((parsed-data (org-element-parse-buffer))
	 (topic (org-gnosis-get-data--topic parsed-data))
	 (nodes (org-gnosis-get-data--nodes parsed-data))
	 (filename (file-name-nondirectory file)))
    `(:file ,filename :topic ,topic :nodes ,nodes)))

(defun org-gnosis-adjust-titles (input)
  "Adjust the INPUT string to replace id link structures with plain text."
  (replace-regexp-in-string "\\[\\[id:[^]]+\\]\\[\\(.*?\\)\\]\\]" "\\1" input))

(defun org-gnosis-get-file-info (filename)
  "Something FILENAME."
  (with-temp-buffer
    (insert-file-contents filename)
    (let* ((data (org-gnosis-get--data filename))
	   (filename (plist-get data :file)))
      data)))

(defun org-gnosis-parse-nodes (nodes top-node inherited-tags)
  "Parse a list of nodes, inheriting tags from the top node.
NODES: list of nodes to parse.
TOP-NODE: the name of the top node to associate with each node.
INHERITED-TAGS: tags from the top node to inherit."
  (cl-loop for (name tags id sub-nodes) in nodes
           ;; Only include nodes with non-nil id
           when id
           append (list (list :category name
                              :tags (append tags inherited-tags)
                              :id id
                              :top-node top-node))
           ;; Recursively parse sub-nodes, inheriting current node's tags
           append (org-gnosis-parse-nodes sub-nodes (when id name) (append tags inherited-tags))))

(defun org-gnosis-parse-data-recursive (data &optional initial-tags)
  "Recursively parse the entire data structure, extracting nodes and details.
DATA: List of top-level categories to start parsing.
INITIAL-TAGS: Initial set of tags to inherit."
  (cl-loop for (node tags id sub-nodes) in data
           ;; Directly parse sub-nodes, using top-level nodes only if they have valid id
           append (when id (list (list :category node
                                       :tags (append tags initial-tags)
                                       :id id
                                       :top-node nil)))
           append (org-gnosis-parse-nodes sub-nodes node (append tags initial-tags))))

;; Org-Gnosis Database

(defconst org-gnosis-db-version 1)

(defconst org-gnosis-db--table-schemata
  '((nodes
     ([(id :not-null :primary-key)
       (file :not-null)
       (title text)
       tags]
      (:foreign-key [file] :references files [file] :on-delete :cascade)))
    (refs
     ([(node-id :not-null)
       (ref :not-null)
       (type :not-null)]
      (:foreign-key [node-id] :references nodes [id] :on-delete :cascade)))
    (links
     ([(source :not-null)
       (dest :not-null)]
      (:foreign-key [source] :references nodes [id] :on-delete :cascade)))))

(defconst org-gnosis-db--table-indices
  '((refs-node-id refs [node-id])))

(defun org-gnosis-db-init ()
  "Initialize database DB with the correct schema and user version."
  (unless (length= (emacsql org-gnosis-db
			    [:select name :from sqlite-master :where (= type table)])
		   7)
    (emacsql-with-transaction org-gnosis-db
      (pcase-dolist (`(,table ,schema) org-gnosis-db--table-schemata)
	(emacsql org-gnosis-db [:create-table $i1 $S2] table schema))
      (pcase-dolist (`(,index-name ,table ,columns) org-gnosis-db--table-indices)
	(emacsql org-gnosis-db [:create-index $i1 :on $i2 $S3] index-name table columns))
      (emacsql org-gnosis-db [:pragma (= user-version org-gnosis-db-version)]))))

(provide 'org-gnosis)
;;; org-gnosis.el ends here
