;;; esi-dictate.el --- Dictation with Real-Time Editing -*- lexical-binding: t; -*-

;; Copyright (c) 2024 Abhinav Tushar

;; Author: Abhinav Tushar <abhinav@lepisma.xyz>
;; Version: 0.1.2
;; Package-Requires: ((emacs "29") (llm "0.17.2"))
;; Keywords: speech
;; URL: https://github.com/lepisma/emacs-speech-input

;;; Commentary:

;; Dictation with Real-Time Editing
;; This file is not a part of GNU Emacs.

;;; License:

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'json)
(require 'llm)
(require 'llm-openai)


(defcustom esi-dictate-dg-api-key nil
  "API Key for Deepgram."
  :type 'string)

(defcustom esi-dictate-llm-provider nil
  "LLM provider to use for corrections")

(defcustom esi-dictate-speech-final-hook nil
  "Hook to keep functions that run once the speech utterance is
finalized from the ASR."
  :type ':hook)

(defvar esi-dictate--dg-process nil
  "Process holding the deepgram script")

(defvar esi-dictate--mode-start-time nil
  "Time when the dictation mode started.

This is used for figuring out correction times.")

(defvar esi-dictate--command-mode-start-time nil
  "Time when command mode was started.")

(defcustom esi-dictate-fix-examples (list (cons "I wan to write about umm something related to food. My name is name is Abhinav"
                                                "I want to write about umm something related to food. My name is Abhinav.")
                                          (cons "Okay we will start. Let's write something about chairs. No not chairs, make it tables."
                                                "Let's write something about tables."))
  "Example inputs and outputs for auto edits. Change this to impact
the behaviour of dictation intelligence."
  :type '(repeat (cons string string)))

(defvar esi-dictate--llm-examples (list (cons "I want to write something that's difficult to transcribe and then try correcting that. Write my name as abcd.\nInstruction: No separate the letters with . please."
                                              "I want to write something that's difficult to transcribe and then try correcting that. Write my name as a.b.c.d.")
                                        (cons "hi easy, what are you doing?\nInstruction: it's e s i"
                                              "hi esi, what are you doing?"))
  "Example inputs and outputs for LLM few-shot learning.")

(defface esi-dictate-intermittent-face
  '((t (:inherit font-lock-comment-face)))
  "Face for transcription that's intermittent and could change
later.")

(defface esi-dictate-command-face
  '((t (:inherit font-lock-warning-face)))
  "Face for transcription that's to be used as correction or
suggestion instructions, also called commands.")

(defvar esi-dictate-mode-map
  (make-sparse-keymap)
  "Keymap for `esi-dictate-mode'.")

(defvar-local esi-dictate--start-position nil
  "Tell the location from where the edit and fixup commands should
start work. If nil, this means start of the line. Otherwise this
specifies buffer local position.")

(define-minor-mode esi-dictate-mode
  "Toggle esi-dictate mode."
  :init-value nil
  :keymap esi-dictate-mode-map)

(defun esi-dictate-start-command-mode ()
  (interactive)
  (setq esi-dictate--command-mode-start-time (current-time)))

(defun esi-dictate-stop-command-mode ()
  (setq esi-dictate--command-mode-start-time nil)
  (message "Stopped command mode"))

(defun esi-dictate-make-edits (content &optional command)
  "Give `command' to the LLM for making edits to the `content' and
return new content."
  (let ((prompt (make-llm-chat-prompt :context "You are a dictation assistant, you will be given transcript by the user and instruction to correct it. You have to return a corrected transcript without changing case of the text unless explicitly asked."
                                      :examples esi-dictate--llm-examples)))
    (llm-chat-prompt-append-response prompt (if command (concat content "\nInstruction: " command) content))
    (llm-chat esi-dictate-llm-provider prompt)))

(defun esi-dictate--fix (content)
  "Perform general fixes to given `content' assuming it's coming
from dictation with speech disfluencies and other artifacts."
  (let ((prompt (make-llm-chat-prompt :context "You are a dictation assistant, you will be given transcript by the user with speech disfluencies, minor mistakes, and edits and you have to return a corrected transcript. The user might give you their stream of consciousness and you have to ensure that you correctly identify a request to edit and don't misfire. You don't have to generate any new information, just ensure fixes in spoken transcripts and edits as asked."
                                      :examples esi-dictate-fix-examples)))
    (llm-chat-prompt-append-response prompt content)
    (llm-chat esi-dictate-llm-provider prompt)))

(defun esi-dictate--get-bounds ()
  "Return a cons cell with starting and ending position of the
region that needs fixing. In the current implementation, this
goes back to the line's beginning at max, unless you have used a
mark."

  (if (region-active-p)
      ;; The user can select a region to be edited too. You can also invoke this
      ;; workflow by setting mark for the starting point. This will work since
      ;; any command will have some text added and a set mark will lead to a
      ;; region.
      (car (region-bounds))
    (let ((beg (or esi-dictate--start-position (line-beginning-position)))
          (end (point)))
      (cons beg end))))

(defun esi-dictate-fix-last ()
  "Fix the last line using the general transcription fixing
instructions."
  (interactive)
  (let ((bounds (esi-dictate--get-bounds)))
    (overlay-put (make-overlay (car bounds) (cdr bounds)) 'face 'esi-dictate-intermittent-face)
    (let ((edited (esi-dictate--fix (buffer-substring-no-properties (car bounds) (cdr bounds)))))
      (delete-region (car bounds) (cdr bounds))
      (insert edited)
      ;; (setq esi-dictate--start-position (point))
      )))

(defun esi-dictate--clear-process ()
  (when esi-dictate--dg-process
    (delete-process esi-dictate--dg-process)
    (setq esi-dictate--dg-process nil)))

(defun esi-dictate-transcription-item-command-p (transcription-item)
  "Tell if the given `transcription-item' is a command.

It does this by tracking the time when the command hotkey was
pressed."
  ;; Only final transcription have reliable time info for this
  (when (and esi-dictate--command-mode-start-time (alist-get 'is_final transcription-item))
    (let ((start-time (time-add esi-dictate--mode-start-time (seconds-to-time (alist-get 'start transcription-item)))))
      (time-less-p esi-dictate--command-mode-start-time start-time))))

(defun esi-dictate-insert (transcription-item)
  "Insert transcription object in the current buffer preserving the
semantics of intermittent results."
  (let ((id (alist-get 'start transcription-item))
        (text (alist-get 'transcript (aref (alist-get 'alternatives (alist-get 'channel transcription-item)) 0)))
        (prev-item (get-text-property (- (point) 1) 'esi-dictate-transcription-item))
        (command-p (esi-dictate-transcription-item-command-p transcription-item)))
    ;; If previous item and current are the same utterance, delete the previous
    ;; item and then insert new one.
    (when (and prev-item (= id (alist-get 'start prev-item)))
      (delete-region (get-text-property (- (point) 1) 'esi-dictate-start) (point)))
    (let ((start (point)))
      (insert text " ")
      (when (eq :false (alist-get 'is_final transcription-item))
        (overlay-put (make-overlay start (point)) 'face 'esi-dictate-intermittent-face))
      (put-text-property start (point) 'esi-dictate-transcription-item transcription-item)
      (put-text-property start (point) 'esi-dictate-start start)

      ;; Recolor current and previous item
      (when command-p
        (overlay-put (make-overlay start (point)) 'face 'esi-dictate-command-face))

      (when (not (eq :false (alist-get 'speech_final transcription-item)))
        ;; This is utterance end according to the ASR. In this case, we run a
        ;; few hooks and, if present, execute explicit commands.
        (run-hooks 'esi-dictate-speech-final-hook)

        (when command-p
          ;; Reset the command mode timer when the utterance has ended.
          (esi-dictate-stop-command-mode)
          ;; Everything in the current line is taken as the content to work on.
          (let* ((command text)
                 (bounds (esi-dictate--get-bounds))
                 (content (buffer-substring-no-properties (car bounds) start))
                 (edited (esi-dictate-make-edits content command)))
            (delete-region (car bounds) (cdr bounds))
            (insert edited " ")))))))

(defun esi-dictate-filter-fn (process string)
  (let ((existing (or (process-get process 'accumulated-output) "")))
    (setq existing (concat existing string))
    (while (string-match "\n" existing)
      (let ((line (substring existing 0 (match-beginning 0)))
            (rest (substring existing (match-end 0))))
        (setq existing rest)
        (cond ((string-prefix-p "Output: " line)
               (let ((json-string (substring line (length "Output: "))))
                 (esi-dictate-insert (json-parse-string json-string :object-type 'alist))))
              ((string-prefix-p "Press Enter to stop recording" line)
               (setq esi-dictate--mode-start-time (current-time))
               (message "Dictation mode ready to use.")))))
    (process-put process 'accumulated-output existing)))

(defun esi-dictate-start ()
  "Start the real-time transcription process to start inserting text
in current buffer."
  (interactive)
  (esi-dictate--clear-process)
  (setq esi-dictate--dg-process
        (let ((process-environment (cons (format "DG_API_KEY=%s" esi-dictate-dg-api-key) process-environment)))
          (make-process :name "esi-dictate-dg"
                        :buffer "*esi-dictate-dg*"
                        :command (list "dg.py")
                        :filter #'esi-dictate-filter-fn)))
  (esi-dictate-mode)
  (message "Starting dictation mode."))

(defun esi-dictate-stop ()
  (interactive)
  (esi-dictate--clear-process)
  (esi-dictate-mode -1)
  (esi-dictate-stop-command-mode)
  (setq esi-dictate--start-position nil)
  (message "Stopped dictation mode."))

(provide 'esi-dictate)

;;; esi-dictate.el ends here
