;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;   Copyright (C) 2006 by Stelian Ionescu                                 ;
;                                                                         ;
;   This program is free software; you can redistribute it and/or modify  ;
;   it under the terms of the GNU General Public License as published by  ;
;   the Free Software Foundation; either version 2 of the License, or     ;
;   (at your option) any later version.                                   ;
;                                                                         ;
;   This program is distributed in the hope that it will be useful,       ;
;   but WITHOUT ANY WARRANTY; without even the implied warranty of        ;
;   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         ;
;   GNU General Public License for more details.                          ;
;                                                                         ;
;   You should have received a copy of the GNU General Public License     ;
;   along with this program; if not, write to the                         ;
;   Free Software Foundation, Inc.,                                       ;
;   51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(declaim (optimize (speed 2) (safety 2) (space 1) (debug 2)))

(in-package #:net.sockets)


(define-constant +resolver-error-map+
  `((#.sb-posix::eai-again    . :resolver-again)
    (#.sb-posix::eai-fail     . :resolver-fail)
    (#.sb-posix::eai-noname   . :resolver-no-name)
    #+linux (#.sb-posix::eai-nodata   . :resolver-no-name)
    #+linux (#.sb-posix::eai-addrfamily . :resolver-no-name)
    (#.sb-posix::eai-service  . :resolver-no-service)
    (#.sb-posix::eai-system   . :resolver-system)
    (#.sb-posix::eai-badflags . :resolver-bad-flags)
    (#.sb-posix::eai-family   . :resolver-family)
    (#.sb-posix::eai-memory   . :resolver-memory)
    (#.sb-posix::eai-socktype . :resolver-socket-type)
    #+linux (#.sb-posix::eai-overflow   . :resolver-overflow)
    #+freebsd (#.sb-posix::eai-badhints . :resolver-bad-hints)
    #+freebsd (#.sb-posix::eai-protocol . :resolver-protocol)
    #+freebsd (#.sb-posix::eai-max      . :resolver-max)))

(defun resolver-error-id (code)
  (cdr (assoc code +resolver-error-map+)))

(defun resolver-error-code (id)
  (cdr (rassoc id +resolver-error-map+)))

(defun raise-resolver-error (&key (type 'resolver-error) code identifier data data-presentation message)
  (error type
         :code (unless code (resolver-error-code identifier))
         :identifier identifier
         :data data
         :data-presentation data-presentation
         :message message))

(define-constant +max-ipv4-value+ (1- (expt 2 32)))


;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;
;;;              ;;;
;;;  HOST LOOKUP ;;;
;;;              ;;;
;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;

(defun get-address-info (&key node service
                         (hint-flags 0) (hint-family 0)
                         (hint-type 0) (hint-protocol 0))
  (with-pinned-aliens ((hints sb-posix::addrinfo)
                       (res (* sb-posix::addrinfo)))
    (sb-posix::memset (addr hints) 0 sb-posix::size-of-addrinfo)
    (setf (slot hints 'sb-posix::flags) hint-flags)
    (setf (slot hints 'sb-posix::family) hint-family)
    (setf (slot hints 'sb-posix::socktype) hint-type)
    (setf (slot hints 'sb-posix::protocol) hint-protocol)
    (sb-posix::getaddrinfo node service (addr hints) (addr res))
    res))

(defun get-name-info (sockaddr &key (want-host t) want-service (flags 0))
  (assert (or want-host want-service))
  (let ((salen (etypecase sockaddr
                 ((alien (* sb-posix::sockaddr-in)) sb-posix::size-of-sockaddr-in)
                 ((alien (* sb-posix::sockaddr-in6)) sb-posix::size-of-sockaddr-in6)
                 ((alien (* sb-posix::sockaddr-storage)) sb-posix::size-of-sockaddr-storage))))
    (with-alien ((host (array char #.sb-posix::ni-maxhost))
                 (service (array char #.sb-posix::ni-maxserv)))
      (sb-sys:with-pinned-objects (sockaddr host service)
        (sb-posix::getnameinfo sockaddr salen
                               (alien-sap host) (if want-host sb-posix::ni-maxhost 0)
                               (alien-sap service) (if want-service sb-posix::ni-maxserv 0)
                               flags))
      (values (and want-host (cast host c-string))
              (and want-service (cast service c-string))))))

(defclass host ()
  ((truename  :initarg :truename  :reader host-truename)
   (aliases   :initarg :aliases   :reader host-aliases)
   (addresses :initarg :addresses :reader host-addresses)))

(defmethod random-address ((host host))
  (with-slots (addresses) host
    (nth (random (length addresses))
         addresses)))

(defun make-host (truename addresses &optional aliases)
  (make-instance 'host
                 :truename truename
                 :aliases aliases
                 :addresses addresses))

(defmethod print-object ((host host) stream)
  (print-unreadable-object (host stream :type t :identity nil)
    (with-slots (truename aliases addresses) host
      (format stream "Cannonical name: ~s. Aliases: ~:[None~;~:*~{~s~^, ~}~].~%Addresses: ~{~a~^, ~}"
              truename aliases addresses))))


;;
;; Error management
;;

(defun manage-resolv-error (retval host port)
  (let ((data (or host port)))
    (case retval
      (#.sb-posix::eai-fail                   ; non-recoverable error
       (raise-resolver-error :type 'resolver-fail-error
                             :data data))
      (#.sb-posix::eai-service                ; non-recoverable error
       (raise-resolver-error :type 'resolver-no-service-error
                             :data (prin1-to-string data)))
      (#.sb-posix::eai-again                  ; temporary error
       (raise-resolver-error :type 'resolver-again-error
                             :data (prin1-to-string data)))
      ((#.sb-posix::eai-noname
        #+linux #.sb-posix::eai-nodata
        #+linux #.sb-posix::eai-addrfamily) ; no name found
       (raise-resolver-error :type 'resolver-no-name-error
                             :data (prin1-to-string data)))
      (#.sb-posix::eai-system                 ; probably a kernel error
       (raise-resolver-error :type 'system-error
                             :code (get-errno)))
      (otherwise
       (let ((id (resolver-error-id retval)))
         (if id
             (raise-resolver-error :identifier id :data data)
             (error "Possible bug while looking up ~a"
                    (if host "host" "port"))))))))

(defun lookup-host-u8-vector-4 (host ipv6)
  (setf host (coerce host '(simple-array ub8 (4))))

  (handler-case
      (ecase ipv6
        ((nil)
         (with-pinned-aliens ((sin sb-posix::sockaddr-in))
           (make-sockaddr-in (addr sin) host)
           (return-from lookup-host-u8-vector-4
             (make-host (get-name-info (addr sin) :flags sb-posix::ni-namereqd)
                        (list (make-address :ipv4 (copy-seq host)))))))

        ((:ipv6 t)
         (with-pinned-aliens ((sin6 sb-posix::sockaddr-in6))
           (let ((ipv6addr (map-ipv4-vector-to-ipv6 host)))
             (make-sockaddr-in6 (addr sin6) ipv6addr)
             (return-from lookup-host-u8-vector-4
               (make-host (get-name-info (addr sin6) :flags sb-posix::ni-namereqd)
                          (list (make-address :ipv6 ipv6addr))))))))
    (sb-posix::resolv-error (err)
      (manage-resolv-error (sb-posix::resolv-errno err) host nil))))

(defun lookup-host-u16-vector-8 (host ipv6)
  (setf host (coerce host '(simple-array ub16 (8))))

  (handler-case
      (ecase ipv6
        ((nil)
         (raise-resolver-error :type 'resolver-fail-error
                               :data host
                               :data-presentation (let ((*print-base* 16)) (format nil "~a" host))
                               :message "Received IPv6 address but IPv4-only was requested."))

        ((:ipv6 t)
         (with-pinned-aliens ((sin6 sb-posix::sockaddr-in6))
           (make-sockaddr-in6 (addr sin6) host)
           (return-from lookup-host-u16-vector-8
             (make-host (get-name-info (addr sin6) :flags sb-posix::ni-namereqd)
                        (list (make-address :ipv6 (copy-seq host))))))))
    (sb-posix::resolv-error (err)
      (manage-resolv-error (sb-posix::resolv-errno err) host nil))))

(defun make-host-from-addrinfo (addrinfo)
  (declare (type (alien (* sb-posix::addrinfo))
                 addrinfo))
  (let ((canonname (slot addrinfo 'sb-posix::canonname))
        (addrlist
         (loop
            :for addrptr :of-type (alien (* sb-posix::addrinfo)) = addrinfo
            :then (slot addrptr 'sb-posix::next)
            :while (not (null-alien addrptr))
            :collect (make-netaddr-from-sockaddr (slot addrptr 'sb-posix::addr)))))
    (make-host canonname addrlist)))

(defun map-host-ipv4-addresses-to-ipv6 (hostobj)
  (declare (type host hostobj))
  (with-slots (addresses) hostobj
    (setf addresses
          (mapcar #'(lambda (a)
                      (if (ipv4-address-p a)
                          (make-address :ipv6 (map-ipv4-vector-to-ipv6 (name a)))
                          a))
                  addresses))))

(defmethod lookup-host :before (host &key (ipv6 *ipv6*))
  (check-type ipv6 (member nil :ipv6 t) "valid IPv6 configuration"))

(defmethod lookup-host ((host string) &key (ipv6 *ipv6*))
  (flet ((decide-family-and-flags ()
           (ecase ipv6
             ((nil) (values sb-posix::af-inet 0))
             ;; the freebsd I use rejects AI_V4MAPPED and AI_ALL(weird thing)
             ;; therefore I'll use AF_UNSPEC and do the mappings myself
             (t     (values
                     #-freebsd sb-posix::af-inet6
                     #+freebsd sb-posix::af-unspec
                     #+freebsd 0
                     #-freebsd
                     (logior sb-posix::ai-v4mapped
                             #+freebsd sb-posix::ai-v4mapped-cfg
                             sb-posix::ai-all)))
             (:ipv6 (values sb-posix::af-inet6 0)))))

    (let (parsed)
      (cond
        ((setf parsed (dotted-to-vector host :error-p nil))
         (return-from lookup-host
           (lookup-host-u8-vector-4 parsed ipv6)))

        ((setf parsed (colon-separated-to-vector host :error-p nil))
         (return-from lookup-host
           (lookup-host-u16-vector-8 parsed ipv6)))

        (t
         (handler-case
             (setf host (coerce host '(simple-array base-char (*))))
           (type-error (err)
             (declare (ignore err))
             (error 'invalid-argument :argument host
                    :message (format nil "The string ~s contains non-ASCII characters." host))))

         (multiple-value-bind (family flags)
             (decide-family-and-flags)
           (setf flags (logior flags sb-posix::ai-canonname sb-posix::ai-addrconfig))
           (handler-case
               (let* ((addrinfo
                       (get-address-info :node host
                                         :hint-flags flags
                                         :hint-family family
                                         :hint-type sb-posix::sock-stream
                                         :hint-protocol sb-posix::ipproto-ip))
                      (hostobj (make-host-from-addrinfo addrinfo)))
                 (when (string-not-equal (host-truename hostobj)
                                         host)
                   (setf (slot-value hostobj 'aliases) (list host)))
                 (sb-posix::freeaddrinfo addrinfo)
                 ;; mapping IPv4 addresses onto IPv6
                 #+freebsd
                 (when (eql ipv6 t)
                   (map-host-ipv4-addresses-to-ipv6 hostobj))
                 (return-from lookup-host hostobj))
             (sb-posix::resolv-error (err)
               (manage-resolv-error (sb-posix::resolv-errno err) host nil)))))))))

(defmethod lookup-host ((host ipv4addr) &key (ipv6 *ipv6*))
  (lookup-host-u8-vector-4 (name host) ipv6))

(defmethod lookup-host ((host ipv6addr) &key (ipv6 *ipv6*))
  (lookup-host-u8-vector-4 (name host) ipv6))

(defmethod lookup-host (host &key (ipv6 *ipv6*))
  (etypecase host
    ((simple-array * (4)) ; IPv4 address
     (lookup-host-u8-vector-4 host ipv6))

    ((simple-array * (8)) ; IPv6 address
     (lookup-host-u16-vector-8 host ipv6))))



;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;
;;;                 ;;;
;;;  SERVICE LOOKUP ;;;
;;;                 ;;;
;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;

(defclass service ()
  ((name     :initarg :name     :reader service-name)
   (port     :initarg :port     :reader service-port)
   (protocol :initarg :protocol :reader service-protocol)))

(defun make-service (name port protocol)
  (make-instance 'service
                 :name name
                 :port port
                 :protocol protocol))

(defmethod print-object ((service service) stream)
  (print-unreadable-object (service stream :type t :identity nil)
    (with-slots (name port protocol) service
      (format stream "Name: ~a. Port: ~a. Protocol: ~a" name port protocol))))

(defun socket-type-from-int (alien-val)
  (case alien-val
    (#.sb-posix::sock-stream    :tcp)
    (#.sb-posix::sock-dgram     :udp)
    (#.sb-posix::sock-seqpacket :sctp)
    (#.sb-posix::sock-raw       :raw)
    (t                          :unknown)))

(defun lookup-service-number (port-number protocol &key name-required)
  (declare (type ub32 port-number))
  (with-pinned-aliens ((sin sb-posix::sockaddr-in))
    (let ((service
           (nth-value 1
            (progn
              (sb-posix::memset (addr sin) 0 sb-posix::size-of-sockaddr-in)
              (setf (slot sin 'sb-posix::family) sb-posix::af-inet)
              (setf (slot sin 'sb-posix::port) (htons port-number))
              (get-name-info (addr sin)
                             :flags (logior
                                     (case protocol
                                       (:udp sb-posix::ni-dgram)
                                       (t 0))
                                     (if name-required
                                         sb-posix::ni-namereqd 0))
                             :want-host nil :want-service t)))))
      (make-service service port-number protocol))))

(defun lookup-service-name (port protocol)
  (let* ((addrinfo
          (the (alien (* sb-posix::addrinfo))
            (get-address-info :service port
                              :hint-type (case protocol
                                           (:tcp sb-posix::sock-stream)
                                           (:udp sb-posix::sock-dgram)
                                           (:any 0)))))
         (port-number
          (ntohs (slot (cast (slot addrinfo 'sb-posix::addr)
                             (* sb-posix::sockaddr-in))
                       'sb-posix::port)))
         (true-protocol
          (socket-type-from-int (slot addrinfo 'sb-posix::socktype))))
    (sb-sys:with-pinned-objects (addrinfo)
      (sb-posix::freeaddrinfo addrinfo))
    (return-from lookup-service-name
      (make-service port port-number true-protocol))))

(defun lookup-service (port &key (protocol :tcp) (name-required nil))
  (case protocol
    ((:tcp :udp :any) t)
    (t                (setf protocol :any)))

  (multiple-value-bind (port-type port-number)
      (string-or-parsed-number port)
    (handler-case
        (case port-type
          (:number
           (lookup-service-number port-number protocol
                                  :name-required name-required))
          (:string
           (lookup-service-name port protocol)))
      (sb-posix:syscall-error (err)
        (manage-resolv-error (sb-posix:syscall-errno err) nil port)))))



;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;
;;;                  ;;;
;;;  PROTOCOL LOOKUP ;;;
;;;                  ;;;
;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;

(defclass protocol ()
  ((name     :initarg :name     :reader protocol-name)
   (aliases  :initarg :aliases  :reader protocol-aliases)
   (protonum :initarg :protonum :reader protocol-number)))

(defun make-protocol (name protonum &optional aliases)
  (make-instance 'protocol
                 :name name
                 :protonum protonum
                 :aliases aliases))

(defmethod print-object ((protocol protocol) stream)
  (print-unreadable-object (protocol stream :type t :identity nil)
    (with-slots (name aliases protonum) protocol
      (format stream "Name: ~s. Protocol number: ~a. Aliases: ~{~s~^, ~}"
              name protonum aliases))))

(defun make-protocol-from-protoent (protoent)
  (declare (type (alien (* sb-posix::protoent)) protoent))
  (let* ((name (slot protoent 'sb-posix::name))
         (number (slot protoent 'sb-posix::proto))
         (aliasptr (slot protoent 'sb-posix::aliases))
         (aliases (loop
                     :for i :from 0
                     :for alias = (deref aliasptr i)
                     :while alias :collect alias)))
    (make-protocol name number aliases)))

(defun get-protocol-by-number (protonum)
  (make-protocol-from-protoent (sb-posix::getprotobynumber protonum)))

(defun get-protocol-by-name (protoname)
  (make-protocol-from-protoent (sb-sys:with-pinned-objects (protoname)
                                 (sb-posix::getprotobyname protoname))))

(defun lookup-protocol (proto)
  (multiple-value-bind (proto-type proto-val)
      (string-or-parsed-number proto)
    (handler-case
        (ecase proto-type
          (:number
           (get-protocol-by-number proto-val))

          (:string
           (get-protocol-by-name proto-val)))
      (sb-posix:syscall-error (err)
        (declare (ignore err))
        (error 'unknown-protocol :name proto)))))