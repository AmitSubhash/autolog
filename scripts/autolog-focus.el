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

(defcustom autolog-focus-today-path
  (expand-file-name "~/org/today.org")
  "Path to the lightweight today file."
  :type 'file
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

(defun autolog-focus--call-payload (&rest args)
  "Call the AutoLog focus helper with ARGS and parse the JSON response."
  (let* ((raw (apply #'autolog-focus--call args))
         (payload (ignore-errors (json-parse-string raw :object-type 'alist))))
    (unless (listp payload)
      (error "AutoLog focus returned invalid JSON: %s" raw))
    payload))

(defun autolog-focus--string (value)
  "Return VALUE as a plain string."
  (if (stringp value) value (format "%s" (or value ""))))

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

(defun autolog-focus-start (task artifact-goal drift-budget done-when)
  "Start a new AutoLog focus block."
  (interactive
   (list
    (read-string "Task: ")
    (read-string "Artifact goal: ")
    (read-number "Drift budget (minutes): " 10)
    (read-string "Done when (optional): ")))
  (let* ((payload (autolog-focus--call-payload
                   "start"
                   "--task" task
                   "--artifact-goal" artifact-goal
                   "--drift-budget" (number-to-string drift-budget)
                   "--done-when" done-when))
         (started-task (autolog-focus--string (alist-get 'task payload)))
         (goal (autolog-focus--string (alist-get 'artifact_goal payload))))
    (message "Started focus block: %s%s"
             started-task
             (if (equal goal "") "" (format " | artifact %s" goal)))))

(defun autolog-focus-stop (artifact next-step notes interrupted)
  "Stop the current AutoLog focus block."
  (interactive
   (list
    (read-string "Artifact: ")
    (read-string "Tomorrow starts with: ")
    (read-string "Notes: ")
    (y-or-n-p "Mark as interrupted? ")))
  (let* ((payload (autolog-focus--call-payload
                   "stop"
                   "--artifact" artifact
                   "--next-step" next-step
                   "--notes" notes
                   "--status" (if interrupted "interrupted" "completed")))
         (task (autolog-focus--string (alist-get 'task payload)))
         (status (capitalize (autolog-focus--string (alist-get 'status payload))))
         (saved-artifact (autolog-focus--string (alist-get 'artifact payload)))
         (saved-next-step (autolog-focus--string (alist-get 'next_step payload))))
    (message "%s focus block: %s%s%s"
             status
             task
             (if (equal saved-artifact "") "" (format " | artifact %s" saved-artifact))
             (if (equal saved-next-step "") "" (format " | next %s" saved-next-step)))))

(defun autolog-focus-status ()
  "Show the current AutoLog focus block."
  (interactive)
  (let ((payload (autolog-focus--call-payload "status")))
    (if (or (null payload) (= (length payload) 0))
        (message "No active focus block.")
      (message "Active: %s | started %s | artifact %s"
               (alist-get 'task payload)
               (alist-get 'started_at payload)
               (or (alist-get 'artifact_goal payload) "-")))))

(defun autolog-focus-open-today ()
  "Create and open today's lightweight todo file."
  (interactive)
  (find-file (autolog-focus--call "today" "--path" autolog-focus-today-path)))

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
