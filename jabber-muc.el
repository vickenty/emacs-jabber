;; jabber-muc.el - advanced MUC functions

;; Copyright (C) 2002, 2003, 2004 - tom berger - object@intelectronica.net
;; Copyright (C) 2003, 2004 - Magnus Henoch - mange@freemail.hu

;; This file is a part of jabber.el.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

(require 'jabber-chat)
(require 'jabber-widget)
(require 'jabber-newdisco)

(require 'cl)

(defvar *jabber-active-groupchats* nil
  "alist of groupchats and nicknames
Keys are strings, the bare JID of the room.
Values are strings.")

(defvar jabber-pending-groupchats (make-hash-table)
  "Hash table of groupchats and nicknames.
Keys are JID symbols; values are strings.
This table records the last nickname used to join the particular
chat room.  Items are thus never removed.")

(defvar jabber-muc-participants nil
  "alist of groupchats and participants
Keys are strings, the bare JID of the room.
Values are lists of nickname strings.")

(defvar jabber-group nil
  "the groupchat you are participating in")

(defvar jabber-muc-topic ""
  "The topic of the current MUC room.")

(defcustom jabber-muc-default-nicknames nil
  "Default nickname for specific MUC rooms."
  :group 'jabber-chat
  :type '(repeat
	  (cons :format "%v"
		(string :tag "JID of room")
		(string :tag "Nickname"))))

(defcustom jabber-muc-autojoin nil
  "List of MUC rooms to automatically join on connection."
  :group 'jabber-chat
  :type '(repeat (string :tag "JID of room")))

(defcustom jabber-groupchat-buffer-format "*-jabber-groupchat-%n-*"
  "The format specification for the name of groupchat buffers.

These fields are available (all are about the group you are chatting
in):

%n   Roster name of group, or JID if no nickname set
%j   Bare JID (without resource)"
  :type 'string
  :group 'jabber-chat)

(defcustom jabber-groupchat-prompt-format "[%t] %n> "
  "The format specification for lines in groupchat.

These fields are available:

%t   Time, formatted according to `jabber-chat-time-format'
%n, %u, %r
     Nickname in groupchat
%j   Full JID (room@server/nick)"
  :type 'string
  :group 'jabber-chat)

(defcustom jabber-muc-header-line-format
  '(" " (:eval (jabber-jid-displayname jabber-group))
    "\t" jabber-muc-topic)
  "The specification for the header line of MUC buffers.

The format is that of `mode-line-format' and `header-line-format'."
  :type 'sexp
  :group 'jabber-chat)

(defcustom jabber-muc-private-buffer-format "*-jabber-muc-priv-%g-%n-*"
  "The format specification for the buffer name for private MUC messages.

These fields are available:

%g   Roster name of group, or JID if no nickname set
%n   Nickname of the group member you're chatting with"
  :type 'string
  :group 'jabber-chat)

(defcustom jabber-muc-private-foreign-prompt-format "[%t] %g/%n> "
  "The format specification for lines others type in a private MUC buffer.

These fields are available:

%t  Time, formatted according to `jabber-chat-time-format'
%n  Nickname in room
%g  Short room name (either roster name or username part of JID)"
  :type 'string
  :group 'jabber-chat)

(defcustom jabber-muc-private-header-line-format
  '(" " (:eval (jabber-jid-resource jabber-chatting-with))
    " in " (:eval (jabber-jid-displayname (jabber-jid-user jabber-chatting-with)))
    "\t" jabber-events-message)
  "The specification for the header line of private MUC chat buffers.

The format is that of `mode-line-format' and `header-line-format'."
  :type 'sexp
  :group 'jabber-chat)

(defvar jabber-muc-printers '()
  "List of functions that may be able to print part of a MUC message.
This gets prepended to `jabber-chat-printers', which see.")

(defun jabber-muc-get-buffer (group)
  "Return the chat buffer for chatroom GROUP.
Either a string or a buffer is returned, so use `get-buffer' or
`get-buffer-create'."
  (format-spec jabber-groupchat-buffer-format
	       (list
		(cons ?n (jabber-jid-displayname group))
		(cons ?j (jabber-jid-user group)))))

(defun jabber-muc-create-buffer (group)
  "Prepare a buffer for chatroom GROUP.
This function is idempotent."
  (with-current-buffer (get-buffer-create (jabber-muc-get-buffer group))
    (unless (eq major-mode 'jabber-chat-mode)
      (jabber-chat-mode #'jabber-chat-pp))

    (set (make-local-variable 'jabber-group) group)
    (make-local-variable 'jabber-muc-topic)
    (setq jabber-send-function 'jabber-muc-send)
    (setq header-line-format jabber-muc-header-line-format)
    (current-buffer)))

(defun jabber-muc-private-get-buffer (group nickname)
  "Return the chat buffer for private chat with NICKNAME in GROUP.
Either a string or a buffer is returned, so use `get-buffer' or
`get-buffer-create'."
  (format-spec jabber-muc-private-buffer-format
	       (list
		(cons ?g (jabber-jid-displayname group))
		(cons ?n nickname))))

(defun jabber-muc-private-create-buffer (group nickname)
  "Prepare a buffer for chatting with NICKNAME in GROUP.
This function is idempotent."
  (with-current-buffer (get-buffer-create (jabber-muc-private-get-buffer group nickname))
    (unless (eq major-mode 'jabber-chat-mode)
      (jabber-chat-mode #'jabber-chat-pp))

    (set (make-local-variable 'jabber-chatting-with) (concat group "/" nickname))
    (setq jabber-send-function 'jabber-chat-send)
    (setq header-line-format jabber-muc-private-header-line-format)

    (current-buffer)))

(defun jabber-muc-send (body)
  "Send BODY to MUC room in current buffer."
  ;; There is no need to display the sent message in the buffer, as
  ;; we will get it back from the MUC server.
  (jabber-send-sexp `(message
		      ((to . ,jabber-group)
		       (type . "groupchat"))
		      (body () ,body))))

(defun jabber-muc-add-groupchat (group nickname)
  "Remember participating in GROUP under NICKNAME."
  (let ((whichgroup (assoc group *jabber-active-groupchats*)))
    (if whichgroup
	(setcdr whichgroup nickname)
      (add-to-list '*jabber-active-groupchats* (cons group nickname)))))

(defun jabber-muc-remove-groupchat (group)
  "Remove GROUP from internal bookkeeping."
  (let ((whichgroup (assoc group *jabber-active-groupchats*))
	(whichparticipants (assoc group jabber-muc-participants)))
    (setq *jabber-active-groupchats* 
	  (delq whichgroup *jabber-active-groupchats*))
    (setq jabber-muc-participants
	  (delq whichparticipants jabber-muc-participants))))

(defun jabber-muc-participant-plist (group nickname)
  "Return plist associated with NICKNAME in GROUP.
Return nil if nothing known about that combination."
  (let ((whichparticipants (assoc group jabber-muc-participants)))
    (when whichparticipants
      (cdr (assoc nickname whichparticipants)))))

(defun jabber-muc-modify-participant (group nickname new-plist)
  "Assign properties in NEW-PLIST to NICKNAME in GROUP."
  (let ((participants (assoc group jabber-muc-participants)))
    ;; either we have a list of participants already...
    (if participants
	(let ((participant (assoc nickname participants)))
	  ;; and maybe this participant is already in the list
	  (if participant
	      ;; if so, just update role, affiliation, etc.
	      (setf (cdr participant) new-plist)
	    (push (cons nickname new-plist) (cdr participants))))
      ;; or we don't
      (push (cons group (list (cons nickname new-plist))) jabber-muc-participants))))

(defun jabber-muc-report-delta (nickname old-plist new-plist reason actor)
  "Compare OLD-PLIST and NEW-PLIST, and return a string explaining the change.
Return nil if nothing noteworthy has happened.
NICKNAME is the user experiencing the change.  REASON and ACTOR, if non-nil,
are the corresponding presence fields.

This function is only concerned with presence stanzas resulting
in the user entering/staying in the room."
  ;; The keys in the plist are affiliation, role and jid.
  (cond
   ((null old-plist)
    ;; User enters the room
    (concat nickname " enters the room ("
	    (plist-get new-plist 'role)
	    (unless (string= (plist-get new-plist 'affiliation) "none")
	      (concat ", " (plist-get new-plist 'affiliation)))
	    ")"))

   ;; If affiliation changes, the role change is usually the logical
   ;; one, so don't report it separately.
   ((not (string= (plist-get old-plist 'affiliation)
		  (plist-get new-plist 'affiliation)))
    (let ((actor-reason (concat (when actor
				  (concat " by " actor))
				(when reason
				  (concat ": " reason))))
	  (from (plist-get old-plist 'affiliation))
	  (to (plist-get new-plist 'affiliation)))
      ;; There are many ways to express these transitions in English.
      ;; This one favors eloquence over regularity and consistency.
      (cond
       ;; Higher affiliation
       ((or (and (member from '("outcast" "none" "member"))
		 (member to '("admin" "owner")))
	    (and (string= from "admin") (string= to "owner")))
	(concat nickname " has been promoted to " to actor-reason))
       ;; Lower affiliation
       ((or (and (member from '("owner" "admin"))
		 (string= to "member"))
	    (and (string= from "owner") (string= to "admin")))
	(concat nickname " has been demoted to " to actor-reason))
       ;; Become member
       ((string= to "member")
	(concat nickname " has been granted membership" actor-reason))
       ;; Lose membership
       ((string= to "none")
	(concat nickname " has been deprived of membership" actor-reason)))))

   ;; Role changes
   ((not (string= (plist-get old-plist 'role)
		  (plist-get new-plist 'role)))
    (let ((actor-reason (concat (when actor
				  (concat " by " actor))
				(when reason
				  (concat ": " reason))))
	  (from (plist-get old-plist 'role))
	  (to (plist-get new-plist 'role)))
      ;; Possible roles are "none" (not in room, hence not of interest
      ;; in this function), "visitor" (no voice), "participant" (has
      ;; voice), and "moderator".
      (cond
       ((string= to "moderator")
	(concat nickname " has been granted moderator privileges" actor-reason))
       ((and (string= from "moderator")
	     (string= to "participant"))
	(concat nickname " had moderator privileges revoked" actor-reason))
       ((string= to "participant")
	(concat nickname " has been granted voice" actor-reason))
       ((string= to "visitor")
	(concat nickname " has been denied voice" actor-reason)))))))

(defun jabber-muc-remove-participant (group nickname)
  "Forget everything about NICKNAME in GROUP."
  (let ((participants (assoc group jabber-muc-participants)))
    (when participants
      (let ((participant (assoc nickname (cdr participants))))
	(setf (cdr participants) (delq participant (cdr participants)))))))

(defun jabber-muc-read-completing (prompt &optional allow-not-joined)
  "Read the name of a joined chatroom, or use chatroom of current buffer, if any.
If ALLOW-NOT-JOINED is provided and true, permit choosing any
JID; only provide completion as a guide."
  (or jabber-group
      (jabber-read-jid-completing prompt
				  (if (null *jabber-active-groupchats*)
				      (error "You haven't joined any group")
				    (mapcar (lambda (x) (jabber-jid-symbol (car x)))
					    *jabber-active-groupchats*))
				  (not allow-not-joined)
				  jabber-group)))

(defun jabber-muc-read-nickname (group prompt)
  "Read the nickname of a participant in GROUP."
  (let ((nicknames (cdr (assoc group jabber-muc-participants))))
    (unless nicknames
      (error "Unknown group: %s" group))
    (completing-read prompt nicknames nil t)))

(add-to-list 'jabber-jid-muc-menu
   (cons "Configure groupchat" 'jabber-groupchat-get-config))
(defun jabber-groupchat-get-config (group)
  "Ask for MUC configuration form"
  (interactive (list (jabber-muc-read-completing "Configure group: " t)))
  (jabber-send-iq group
		  "get"
		  '(query ((xmlns . "http://jabber.org/protocol/muc#owner")))
		  #'jabber-process-data #'jabber-groupchat-render-config
		  #'jabber-process-data "MUC configuration request failed"))

(defun jabber-groupchat-render-config (xml-data)
  "Render MUC configuration form"

  (let ((query (jabber-iq-query xml-data))
	xdata)
    (dolist (x (jabber-xml-get-children query 'x))
      (if (string= (jabber-xml-get-attribute x 'xmlns) "jabber:x:data")
	  (setq xdata x)))
    (if (not xdata)
	(insert "No configuration possible.\n")
      
    (jabber-init-widget-buffer (jabber-xml-get-attribute xml-data 'from))

    (jabber-render-xdata-form xdata)

    (widget-create 'push-button :notify #'jabber-groupchat-submit-config "Submit")
    (widget-insert "\t")
    (widget-create 'push-button :notify #'jabber-groupchat-cancel-config "Cancel")
    (widget-insert "\n")

    (widget-setup)
    (widget-minor-mode 1))))

(defun jabber-groupchat-submit-config (&rest ignore)
  "Submit MUC configuration form."

  (jabber-send-iq jabber-submit-to
		  "set"
		  `(query ((xmlns . "http://jabber.org/protocol/muc#owner"))
			  ,(jabber-parse-xdata-form))
		  #'jabber-report-success "MUC configuration"
		  #'jabber-report-success "MUC configuration"))

(defun jabber-groupchat-cancel-config (&rest ignore)
  "Cancel MUC configuration form."

  (jabber-send-iq jabber-submit-to
		  "set"
		  '(query ((xmlns . "http://jabber.org/protocol/muc#owner"))
			  (x ((xmlns . "jabber:x:data") (type . "cancel"))))
		  nil nil nil nil))

(add-to-list 'jabber-jid-muc-menu
	     (cons "Join groupchat" 'jabber-groupchat-join))

(defun jabber-groupchat-join (group nickname)
  "join a groupchat, or change nick"
  (interactive 
   (let ((group (jabber-read-jid-completing "group: ")))
     (list group (jabber-muc-read-my-nickname group))))

  ;; If the user is already in the room, we don't need as many checks.
  (if (assoc group *jabber-active-groupchats*)
      (jabber-groupchat-join-3 group nickname nil (interactive-p))
    ;; Else, send a disco request to find out what we are connecting
    ;; to.
    (jabber-disco-get-info group nil #'jabber-groupchat-join-2
			   (list group nickname (interactive-p)))))

(defun jabber-groupchat-join-2 (closure result)
  (destructuring-bind (group nickname interactive) closure
    (let ( ;; Either success...
	  (identities (car result))
	  (features (cadr result))
	  ;; ...or error
	  (condition (when (eq (car result) 'error) (jabber-error-condition result))))
      (cond
       ;; Maybe the room doesn't exist yet.
       ((eq condition 'item-not-found)
	(unless (y-or-n-p (format "%s doesn't exist.  Create it? " (jabber-jid-displayname group)))
	  (error "Non-existent groupchat")))

       ;; Maybe another error occurred.
       (condition
	(error "Couldn't query groupchat: %s" (jabber-parse-error result)))

       ;; Maybe it isn't a chat room.
       ((not (find "conference" identities 
		   :key (lambda (i) (aref i 1))
		   :test #'string=))
	(error "%s is not a groupchat" (jabber-jid-displayname group))))

      (let ((password
	     ;; Is the room password-protected?
	     (when (member "muc_passwordprotected" features)
	       (read-passwd (format "Password for %s: " (jabber-jid-displayname group))))))

	(jabber-groupchat-join-3 group nickname password interactive)))))

(defun jabber-groupchat-join-3 (group nickname password interactive)

  ;; Remember that this is a groupchat _before_ sending the stanza.
  ;; The response might come quicker than you think.

  (puthash (jabber-jid-symbol group) nickname jabber-pending-groupchats)
  
  (jabber-send-sexp `(presence ((to . ,(format "%s/%s" group nickname)))
			       (x ((xmlns . "http://jabber.org/protocol/muc"))
				  ,@(when password
				      `((password () ,password))))))

  ;; There, stanza sent.  Now we just wait for the MUC service to
  ;; mirror the stanza.  This is handled in
  ;; `jabber-muc-process-presence', where a buffer will be created for
  ;; the room.

  ;; But if the user interactively asked to join, he/she probably
  ;; wants the buffer to pop up right now.
  (when interactive
    (let ((buffer (jabber-muc-create-buffer group)))
      (switch-to-buffer buffer))))

(defun jabber-muc-read-my-nickname (group)
  "Read nickname for joining GROUP."
  (let ((default-nickname (or
			   (cdr (assoc group jabber-muc-default-nicknames))
			   jabber-nickname)))
    (jabber-read-with-input-method (format "Nickname: (default %s) "
					   default-nickname) 
				   nil nil default-nickname)))

(add-to-list 'jabber-jid-muc-menu
	     (cons "Change nickname" 'jabber-muc-nick))

(defalias 'jabber-muc-nick 'jabber-groupchat-join)

(add-to-list 'jabber-jid-muc-menu
	     (cons "Leave groupchat" 'jabber-groupchat-leave))

(defun jabber-groupchat-leave (group)
  "leave a groupchat"
  (interactive (list (jabber-muc-read-completing "Leave which group: ")))
  (let ((whichgroup (assoc group *jabber-active-groupchats*)))
    ;; send unavailable presence to our own nick in room
    (jabber-send-sexp `(presence ((to . ,(format "%s/%s" group (cdr whichgroup)))
				  (type . "unavailable"))))))

(add-to-list 'jabber-jid-muc-menu
	     (cons "List participants" 'jabber-muc-names))

(defun jabber-muc-names (group)
  "Print names, affiliations, and roles of participants in GROUP."
  (interactive (list (jabber-muc-read-completing "Group: ")))
  (with-current-buffer (jabber-muc-create-buffer group)
    (ewoc-enter-last jabber-chat-ewoc (list :notice
					    (jabber-muc-print-names
					     (cdr (assoc group jabber-muc-participants)))
					    :time (current-time)))
    ;; (let ((jabber-chat-fill-long-lines nil))
;;       (jabber-chat-buffer-display 'jabber-muc-system-prompt nil
;; 				  '(jabber-muc-print-names)
;; 				  (cdr (assoc group jabber-muc-participants))))
    ))

(defun jabber-muc-print-names (participants)
  "Format and return data in PARTICIPANTS."
  (apply 'concat "Participants:\n"
	 (format "%-15s %-15s %-11s %s\n" "Nickname" "Role" "Affiliation" "JID")
	 (mapcar (lambda (x)
		   (let ((plist (cdr x)))
		     (format "%-15s %-15s %-11s %s\n"
			     (car x)
			     (plist-get plist 'role)
			     (plist-get plist 'affiliation)
			     (or (plist-get plist 'jid) ""))))
		 participants)))

(add-to-list 'jabber-jid-muc-menu
	     (cons "Set topic" 'jabber-muc-set-topic))

(defun jabber-muc-set-topic (group topic)
  "Set topic of GROUP to TOPIC."
  (interactive
   (let ((group (jabber-muc-read-completing "Group: ")))
     (list group
	   (jabber-read-with-input-method "New topic: " jabber-muc-topic))))
  (jabber-send-message group topic nil "groupchat"))

(defun jabber-muc-snarf-topic (xml-data)
  "Record subject (topic) of the given <message/>, if any."
  (let ((new-topic (jabber-xml-path xml-data '(subject ""))))
    (when new-topic
      (setq jabber-muc-topic new-topic))))

(add-to-list 'jabber-jid-muc-menu
	     (cons "Set role (kick, voice, op)" 'jabber-muc-set-role))

(defun jabber-muc-set-role (group nickname role reason)
  "Set role of NICKNAME in GROUP to ROLE, specifying REASON."
  (interactive
   (let* ((group (jabber-muc-read-completing "Group: "))
	  (nickname (jabber-muc-read-nickname group "Nickname: ")))
     (list group nickname
	   (completing-read "New role: " '(("none") ("visitor") ("participant") ("moderator")) nil t)
	   (read-string "Reason: "))))
  (unless (or (zerop (length nickname)) (zerop (length role)))
    (jabber-send-iq group "set"
		    `(query ((xmlns . "http://jabber.org/protocol/muc#admin"))
			    (item ((nick . ,nickname)
				   (role . ,role))
				  ,(unless (zerop (length reason))
				     `(reason () ,reason))))
		    'jabber-report-success "Role change"
		    'jabber-report-success "Role change")))

(add-to-list 'jabber-jid-muc-menu
	     (cons "Set affiliation (ban, member, admin)" 'jabber-muc-set-affiliation))

(defun jabber-muc-set-affiliation (group nickname-or-jid nickname-p affiliation reason)
  "Set affiliation of NICKNAME-OR-JID in GROUP to AFFILIATION.
If NICKNAME-P is non-nil, NICKNAME-OR-JID is a nickname in the
group, else it is a JID."
  (interactive
   (let ((group (jabber-muc-read-completing "Group: "))
	 (nickname-p (y-or-n-p "Specify user by room nickname? ")))
     (list
      group
      (if nickname-p
	  (jabber-muc-read-nickname group "Nickname: ")
	(jabber-read-jid-completing "User: "))
      nickname-p
      (completing-read "New affiliation: "
		       '(("none") ("outcast") ("member") ("admin") ("owner")) nil t)
      (read-string "Reason: "))))
  (let ((jid
	 (if nickname-p
	     (let ((participants (cdr (assoc group jabber-muc-participants))))
	       (unless participants
		 (error "Couldn't find group %s" group))
	       (let ((participant (cdr (assoc nickname-or-jid participants))))
		 (unless participant
		   (error "Couldn't find %s in group %s" nickname-or-jid group))
		 (or (plist-get participant 'jid)
		     (error "JID of %s in group %s is unknown" nickname-or-jid group))))
	   nickname-or-jid)))
    (jabber-send-iq group "set"
		    `(query ((xmlns . "http://jabber.org/protocol/muc#admin"))
			    (item ((jid . ,jid)
				   (affiliation . ,affiliation))
				  ,(unless (zerop (length reason))
				     `(reason () ,reason))))
		    'jabber-report-success "Affiliation change"
		    'jabber-report-success "Affiliation change")))

(add-to-list 'jabber-jid-muc-menu
	     (cons "Invite someone to chatroom" 'jabber-muc-invite))

(defun jabber-muc-invite (jid group reason)
  "Invite JID to GROUP, stating REASON."
  (interactive
   (list (jabber-read-jid-completing "Invite whom: ")
	 (jabber-muc-read-completing "To group: ")
	 (jabber-read-with-input-method "Reason: ")))
  (jabber-send-sexp
   `(message ((to . ,group))
	     (x ((xmlns . "http://jabber.org/protocol/muc#user"))
		(invite ((to . ,jid))
			,(unless (zerop (length reason))
			   `(reason nil ,reason)))))))

(add-to-list 'jabber-body-printers 'jabber-muc-print-invite)

(defun jabber-muc-print-invite (xml-data who mode)
  "Print MUC invitation"
  (dolist (x (jabber-xml-get-children xml-data 'x))
    (when (string= (jabber-xml-get-attribute x 'xmlns) "http://jabber.org/protocol/muc#user")
      (let ((invitation (car (jabber-xml-get-children x 'invite))))
	(when invitation
	  (when (eql mode :insert)
	    (let ((group (jabber-xml-get-attribute xml-data 'from))
		  (inviter (jabber-xml-get-attribute invitation 'from))
		  (reason (car (jabber-xml-node-children (car (jabber-xml-get-children invitation 'reason))))))
	      ;; XXX: password
	      (insert "You have been invited to MUC room " (jabber-jid-displayname group))
	      (when inviter
		(insert " by " (jabber-jid-displayname inviter)))
	      (insert ".")
	      (when reason
		(insert "  Reason: " reason))
	      (insert "\n\n")

	      (let ((action
		     `(lambda (&rest ignore) (interactive)
			(jabber-groupchat-join ,group
					       (jabber-muc-read-my-nickname ,group)))))
		(if (fboundp 'insert-button)
		    (insert-button "Accept"
				   'action action)
		  ;; Simple button replacement
		  (let ((keymap (make-keymap)))
		    (define-key keymap "\r" action)
		    (insert (jabber-propertize "Accept"
					       'keymap keymap
					       'face 'highlight))))

		(insert "\t")

		(let ((action
		       `(lambda (&rest ignore) (interactive)
			  (let ((reason
				 (jabber-read-with-input-method
				  "Reason: ")))
			    (jabber-send-sexp
			     (list 'message
				   (list (cons 'to ,group))
				   (list 'x
					 (list (cons 'xmlns "http://jabber.org/protocol/muc#user"))
					 (list 'decline
					       (list (cons 'to ,inviter))
					       (unless (zerop (length reason))
						 (list 'reason nil reason))))))))))
		  (if (fboundp 'insert-button)
		      (insert-button "Decline"
				     'action action)
		    ;; Simple button replacement
		    (let ((keymap (make-keymap)))
		      (define-key keymap "\r" action)
		      (insert (jabber-propertize "Decline"
						 'keymap keymap
						 'face 'highlight))))))))
	  (return t))))))

(defun jabber-muc-autojoin ()
  "Join rooms specified in variable `jabber-muc-autojoin'."
  (interactive)
  (dolist (group jabber-muc-autojoin)
    (jabber-groupchat-join group (or
				  (cdr (assoc group jabber-muc-default-nicknames))
				  jabber-nickname))))

(defun jabber-muc-message-p (message)
  "Return non-nil if MESSAGE is a groupchat message.
That does not include private messages in a groupchat."
  ;; Public groupchat messages have type "groupchat" and are from
  ;; room@server/nick.  Public groupchat errors have type "error" and
  ;; are from room@server.
  (let ((from (jabber-xml-get-attribute message 'from))
	(type (jabber-xml-get-attribute message 'type)))
    (or 
     (string= type "groupchat")
     (and (string= type "error")
	  (gethash (jabber-jid-symbol from) jabber-pending-groupchats)))))

(defun jabber-muc-sender-p (jid)
  "Return non-nil if JID is a full JID of an MUC participant."
  (and (assoc (jabber-jid-user jid) *jabber-active-groupchats*)
       (jabber-jid-resource jid)))

(defun jabber-muc-private-message-p (message)
  "Return non-nil if MESSAGE is a private message in a groupchat."
  (let ((from (jabber-xml-get-attribute message 'from))
	(type (jabber-xml-get-attribute message 'type)))
    (and
     (not (string= type "groupchat"))
     (jabber-muc-sender-p from))))

(add-to-list 'jabber-jid-muc-menu
	     (cons "Open private chat" 'jabber-muc-private))

(defun jabber-muc-private (group nickname)
  "Open private chat with NICKNAME in GROUP."
  (interactive
   (let* ((group (jabber-muc-read-completing "Group: "))
	  (nickname (jabber-muc-read-nickname group "Nickname: ")))
     (list group nickname)))
  (switch-to-buffer (jabber-muc-private-create-buffer group nickname)))

(defun jabber-muc-presence-p (presence)
  "Return non-nil if PRESENCE is presence from groupchat."
  (let ((from (jabber-xml-get-attribute presence 'from))
	(type (jabber-xml-get-attribute presence 'type))
	(muc-marker (find-if 
		     (lambda (x) (equal (jabber-xml-get-attribute x 'xmlns)
				   "http://jabber.org/protocol/muc#user"))
		     (jabber-xml-get-children presence 'x))))
    ;; This is MUC presence if it has an MUC-namespaced tag...
    (or muc-marker
	;; ...or if it is error presence from a room we tried to join.
	(and (string= type "error")
	     (gethash (jabber-jid-symbol from) jabber-pending-groupchats)))))

(defun jabber-muc-parse-affiliation (x-muc)
  "Parse X-MUC in the muc#user namespace and return a plist.
Return nil if X-MUC is nil."
  ;; XXX: parse <actor/> and <reason/> tags?  or maybe elsewhere?
  (apply 'nconc (mapcar (lambda (prop) (list (car prop) (cdr prop)))
			(jabber-xml-node-attributes
			 (car (jabber-xml-get-children x-muc 'item))))))

(defun jabber-muc-print-prompt (xml-data)
  "Print MUC prompt for message in XML-DATA."
  (let ((nick (jabber-jid-resource (jabber-xml-get-attribute xml-data 'from)))
	(timestamp (car (delq nil (mapcar 'jabber-x-delay (jabber-xml-get-children xml-data 'x))))))
    (if (stringp nick)
	(insert (jabber-propertize
		 (format-spec jabber-groupchat-prompt-format
			      (list
			       (cons ?t (format-time-string 
					 (if timestamp
					     jabber-chat-delayed-time-format
					   jabber-chat-time-format)
					 timestamp))
			       (cons ?n nick)
			       (cons ?u nick)
			       (cons ?r nick)
			       (cons ?j (concat jabber-group "/" nick))))
		 'face 'jabber-chat-prompt-foreign
		 'help-echo (concat (format-time-string "On %Y-%m-%d %H:%M:%S" timestamp) " from " nick " in " jabber-group)))
      (jabber-muc-system-prompt))))

(defun jabber-muc-private-print-prompt (xml-data)
  "Print prompt for private MUC message in XML-DATA."
  (let ((nick (jabber-jid-resource (jabber-xml-get-attribute xml-data 'from)))
	(group (jabber-jid-user (jabber-xml-get-attribute xml-data 'from)))
	(timestamp (car (delq nil (mapcar 'jabber-x-delay (jabber-xml-get-children xml-data 'x))))))
    (insert (jabber-propertize
	     (format-spec jabber-muc-private-foreign-prompt-format
			  (list
			   (cons ?t (format-time-string 
				     (if timestamp
					 jabber-chat-delayed-time-format
				       jabber-chat-time-format)
				     timestamp))
			   (cons ?n nick)
			   (cons ?g (or (jabber-jid-rostername group)
					(jabber-jid-username group)))))
	     'face 'jabber-chat-prompt-foreign
	     'help-echo (concat (format-time-string "On %Y-%m-%d %H:%M:%S" timestamp) " from " nick " in " jabber-group)))))

(defun jabber-muc-system-prompt (&rest ignore)
  "Print system prompt for MUC."
  (insert (jabber-propertize
	   (format-spec jabber-groupchat-prompt-format
			(list
			 (cons ?t (format-time-string jabber-chat-time-format))
			 (cons ?n "")
			 (cons ?u "")
			 (cons ?r "")
			 (cons ?j jabber-group)))
	   'face 'jabber-chat-prompt-system
	   'help-echo (format-time-string "System message on %Y-%m-%d %H:%M:%S"))))

(add-to-list 'jabber-message-chain 'jabber-muc-process-message)

(defun jabber-muc-process-message (xml-data)
  "If XML-DATA is a groupchat message, handle it as such."
  (when (jabber-muc-message-p xml-data)
    (let* ((from (jabber-xml-get-attribute xml-data 'from))
	   (group (jabber-jid-user from))
	   (nick (jabber-jid-resource from))
	   (error-p (jabber-xml-get-children xml-data 'error))
	   (type (cond 
		  (error-p :muc-error)
		  ((string= nick (cdr (assoc group *jabber-active-groupchats*)))
		   :muc-local)
		  (t :muc-foreign)))
	   (body-text (car (jabber-xml-node-children
			   (car (jabber-xml-get-children
				 xml-data 'body)))))

	   (printers (append jabber-muc-printers jabber-chat-printers)))

      (with-current-buffer (jabber-muc-create-buffer group)
	(jabber-muc-snarf-topic xml-data)
	;; Call alert hooks only when something is output
	(when (or error-p
		  (run-hook-with-args-until-success 'printers xml-data type :printp))
	  (jabber-maybe-print-rare-time
	   (ewoc-enter-last jabber-chat-ewoc (list type xml-data :time (current-time))))
	  
	  (dolist (hook '(jabber-muc-hooks jabber-alert-muc-hooks))
	    (run-hook-with-args hook
				nick group (current-buffer) body-text
				(funcall jabber-alert-muc-function
					 nick group (current-buffer) body-text))))))))

(defun jabber-muc-process-presence (presence)
  (let* ((from (jabber-xml-get-attribute presence 'from))
	 (type (jabber-xml-get-attribute presence 'type))
	 (x-muc (find-if 
		 (lambda (x) (equal (jabber-xml-get-attribute x 'xmlns)
			       "http://jabber.org/protocol/muc#user"))
		 (jabber-xml-get-children presence 'x)))
	 (group (jabber-jid-user from))
	 (nickname (jabber-jid-resource from))
	 (symbol (jabber-jid-symbol from))
	 (item (car (jabber-xml-get-children x-muc 'item)))
	 (actor (jabber-xml-get-attribute (car (jabber-xml-get-children item 'actor)) 'jid))
	 (reason (car (jabber-xml-node-children (car (jabber-xml-get-children item 'reason)))))
	 (status-code (jabber-xml-get-attribute
		       (car (jabber-xml-get-children x-muc 'status))
		       'code))
	 (error-node (car (jabber-xml-get-children presence 'error))))
    ;; handle leaving a room
    (cond 
     ((or (string= type "unavailable") (string= type "error"))
      ;; are we leaving?
      (if (string= nickname (gethash (jabber-jid-symbol group) jabber-pending-groupchats))
	  (let ((message (cond
			  ((string= type "error")
			   (concat "Error entering room"
				   (when error-node
				     (concat ": " (jabber-parse-error error-node)))))
			  ((equal status-code "301")
			   (concat "You have been banned"
				   (when actor (concat " by " actor))
				   (when reason (concat " - '" reason "'"))))
			  ((equal status-code "307")
			   (concat "You have been kicked"
				   (when actor (concat " by " actor))
				   (when reason (concat " - '" reason "'"))))
			  (t
			   "You have left the chatroom"))))
	    (jabber-muc-remove-groupchat group)
	    ;; If there is no buffer for this groupchat, don't bother
	    ;; creating one just to tell that user left the room.
	    (let ((buffer (get-buffer (jabber-muc-get-buffer group))))
	      (if buffer
		  (with-current-buffer buffer
		    (jabber-maybe-print-rare-time
		     (ewoc-enter-last jabber-chat-ewoc
				      (list (if (string= type "error")
						:muc-error
					      :muc-notice)
					    message
					    :time (current-time)))))
		(message "%s: %s" (jabber-jid-displayname group) message))))
	;; or someone else?
	(jabber-muc-remove-participant group nickname)
	(with-current-buffer (jabber-muc-create-buffer group)
	  (jabber-maybe-print-rare-time
	   (ewoc-enter-last
	    jabber-chat-ewoc
	    (list :muc-notice
		  (cond
		   ((equal status-code "301")
		    (concat nickname " has been banned"
			    (when actor (concat " by " actor))
			    (when reason (concat " - '" reason "'"))))
		   ((equal status-code "307")
		    (concat nickname " has been kicked"
			    (when actor (concat " by " actor))
			    (when reason (concat " - '" reason "'"))))
		   ((equal status-code "303")
		    (concat nickname " changes nickname to "
			    (jabber-xml-get-attribute item 'nick)))
		   (t
		    (concat nickname " has left the chatroom")))
		  :time (current-time)))))))
     (t 
      ;; someone is entering

      (when (string= nickname (gethash (jabber-jid-symbol group) jabber-pending-groupchats))
	;; Our own nick?  We just succeeded in entering the room.
	(let ((whichgroup (assoc group *jabber-active-groupchats*)))
	  (if whichgroup
	      (setcdr whichgroup nickname)
	    (add-to-list '*jabber-active-groupchats* (cons group nickname)))))	

      ;; Whoever enters, we create a buffer (if it didn't already
      ;; exist), and print a notice.  This is where autojoined MUC
      ;; rooms have buffers created for them.  We also remember some
      ;; metadata.
      (let ((old-plist (jabber-muc-participant-plist group nickname))
	    (new-plist (jabber-muc-parse-affiliation x-muc)))
	(jabber-muc-modify-participant group nickname new-plist)
	(let ((report (jabber-muc-report-delta nickname old-plist new-plist
					       reason actor)))
	  (when report
	    (with-current-buffer (jabber-muc-create-buffer group)
	      (jabber-maybe-print-rare-time
	       (ewoc-enter-last
		jabber-chat-ewoc
		(list :muc-notice report
		      :time (current-time))))))))))))
	      
(provide 'jabber-muc)

;;; arch-tag: 1ff7ab35-1717-46ae-b803-6f5b3fb2cd7d
