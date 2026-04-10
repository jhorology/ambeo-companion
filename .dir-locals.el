((swift-mode
  . ((eval . (with-eval-after-load 'dape
               (let ((selected-target nil))
                 (setf (alist-get 'swift-debug-spm dape-configs)
                       `( ;; common settings
                         command ,(car (last (file-expand-wildcards "~/.vscode/extensions/vadimcn.vscode-lldb-*/adapter/codelldb")))
                         command-args ("--port" :autoport)
                         port :autoport
                         modes (swift-mode)
                         ensure dape-ensure-command

                         ;; select traget
                         fn ,(lambda (config)
                               (let* ((cwd (plist-get config :cwd))
                                      ;; list executable targget inside Pckage.swift
                                      (pkg-file (expand-file-name "Package.swift" cwd))
                                      (targets (when (file-exists-p pkg-file)
                                                 (split-string
                                                  (shell-command-to-string
                                                   (format "sed -n '/executableTarget/,/name:/ s/.*name:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' %s" pkg-file))
                                                  "\n" t)))
                                      (target (or selected-target
                                                  (setq selected-target
                                                        (if (> (length targets) 1)
                                                            (completing-read "Select Swift Target: " targets nil t)
                                                          (car targets)))))
                                      (sdk (string-trim (shell-command-to-string "xcrun --show-sdk-path --sdk macosx"))))

                                 (plist-put config 'compile (format "swift build --product %s -Xswiftc -D -Xswiftc DEBUG" target))
                                 (plist-put config :program (concat cwd ".build/arm64-apple-macosx/debug/" target))
                                 (plist-put config :env (list :SDKROOT sdk))

                                 ;; clear taget
                                 (run-at-time 1 nil (lambda () (setq selected-target nil)))

                                 config))

                         :type "lldb"
                         :request "launch"
                         :cwd dape-cwd))))))))
