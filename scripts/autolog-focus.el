(defgroup autolog-focus nil
  "Emacs helpers for AutoLog focus blocks."
  :group 'tools)

(defcustom autolog-focus-python "python3"
  "Python executable used for the AutoLog focus helper."
  :type 'string
  :group 'autolog-focus)

(defcustom autolog-focus-script
  (expand-file-name "focus_state.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the AutoLog focus helper script."
  :type 'file
  :group 'autolog-focus)

(defcustom autolog-focus-buffer-name "*AutoLog Focus*"
  "Base buffer name used for AutoLog focus views."
  :type 'string
  :group 'autolog-focus)

(defun autolog-focus--call (&rest args)
  "Call the AutoLog focus helper with ARGS and return trimmed stdout."
  (with-temp-buffer
    (let ((status (apply #'call-process
                         autolog-focus-python
                         nil
                         (current-buffer)
                         nil
                         autolog-focus-script
                         args)))
      (unless (eq status 0)
        (error "AutoLog focus command failed: %s" (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun autolog-focus--display-buffer (name content)
  "Display CONTENT in a read-only buffer called NAME."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert content)
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer buffer)))

(defun autolog-focus-start (task done-when artifact-goal drift-budget)
  "Start a new AutoLog focus block."
  (interactive
   (list
    (read-string "Task: ")
    (read-string "Done when: ")
    (read-string "Artifact goal: ")
    (read-number "Drift budget (minutes): " 10)))
  (message "%s"
           (autolog-focus--call
            "start"
            "--task" task
            "--done-when" done-when
            "--artifact-goal" artifact-goal
            "--drift-budget" (number-to-string drift-budget))))

(defun autolog-focus-stop (artifact score notes)
  "Stop the current AutoLog focus block."
  (interactive
   (list
    (read-string "Artifact: ")
    (read-number "Score (0-10): " 8)
    (read-string "Notes: ")))
  (message "%s"
           (autolog-focus--call
            "stop"
            "--artifact" artifact
            "--score" (number-to-string score)
            "--notes" notes)))

(defun autolog-focus-status ()
  "Show the current AutoLog focus block."
  (interactive)
  (let* ((raw (autolog-focus--call "status"))
         (payload (ignore-errors (json-parse-string raw :object-type 'alist))))
    (if (or (null payload) (= (length payload) 0))
        (message "No active focus block.")
      (message "Active: %s | started %s | artifact %s"
               (alist-get 'task payload)
               (alist-get 'started_at payload)
               (or (alist-get 'artifact_goal payload) "-")))))

(defun autolog-focus-open-scorecard ()
  "Create and open today's scorecard."
  (interactive)
  (find-file (autolog-focus--call "scorecard")))

(defun autolog-focus-list-blocks (&optional limit)
  "Show recent focus blocks in a readable buffer."
  (interactive "P")
  (autolog-focus--display-buffer
   autolog-focus-buffer-name
   (autolog-focus--call "list" "--include-open" "--limit"
                        (number-to-string (prefix-numeric-value (or limit 12))))))

(defun autolog-focus-productivity (&optional days)
  "Show productivity summary for recent focus blocks."
  (interactive "P")
  (autolog-focus--display-buffer
   "*AutoLog Productivity*"
   (autolog-focus--call "productivity" "--days"
                        (number-to-string (prefix-numeric-value (or days 7))))))

(provide 'autolog-focus)
