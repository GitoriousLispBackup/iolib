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

;; (declaim (optimize (speed 2) (safety 2) (space 1) (debug 2)))
(declaim (optimize (speed 0) (safety 2) (space 0) (debug 2)))

(in-package #:io.multiplex)

(defclass select-multiplex-interface (multiplex-interface) ())

(defconstant +select-priority+ 3)

(pushnew (cons +select-priority+ 'select-multiplex-interface)
         *multiplex-available-interfaces*)

(defun fd-open-p (fd)
  (sb-alien:with-alien ((stat et:stat))
    (handler-case
        (progn (et:stat fd (addr stat)) t)
      (et:unix-error-badf (err)
        (declare (ignore err))
        nil))))

(defmethod select-setup-masks ((interface select-multiplex-interface)
                               read-fds write-fds except-fds)
  (declare (type system-area-pointer
                 read-fds write-fds except-fds))

  (et:fd-zero read-fds)
  (et:fd-zero write-fds)
  (et:fd-zero except-fds)

  (let ((max-fd 0))
    (with-slots (fd-handlers) interface
      (with-hash-table-iterator (next-item fd-handlers)
        (multiple-value-bind (item-p fd handler) (next-item)
          (when item-p
            (if (fd-open-p fd)
                (progn
                  (when (> fd max-fd)
                    (setf max-fd fd))
                  (when (handler-read-func handler)
                    (et:fd-set fd read-fds))
                  (when (handler-write-func handler)
                    (et:fd-set fd write-fds))
                  (when (handler-except-func handler)
                    (et:fd-set fd except-fds)))
                ;; TODO: add better error handling
                (error "Handlers for bad fd(s) are present !!")))))
      (incf max-fd))))

(defmethod serve-events ((interface select-multiplex-interface))
  (sb-alien:with-alien ((read-fds et:fd-set)
                        (write-fds et:fd-set)
                        (except-fds et:fd-set))

    (let ((max-fd (select-setup-masks
                   interface
                   (alien-sap read-fds)
                   (alien-sap write-fds)
                   (alien-sap except-fds))))

      (with-slots (fd-handlers) interface
        (tagbody
         :start
           (handler-case
               (et:select max-fd
                          (addr read-fds) (addr write-fds) (addr except-fds)
                          nil)
             (et:unix-error-intr (err)
               (declare (ignore err))
               (go :start))))

        (with-hash-table-iterator (next-item fd-handlers)
          (multiple-value-bind (item-p fd handler) (next-item)
            (when item-p
              (if (fd-open-p fd)
                  (progn
                    (when (and (et:fd-isset fd (alien-sap except-fds))
                               (handler-except-func handler))
                      (funcall (handler-except-func handler) fd))
                    (when (and (et:fd-isset fd (alien-sap read-fds))
                               (handler-read-func handler))
                      (funcall (handler-read-func handler) fd))
                    (when (and (et:fd-isset fd (alien-sap write-fds))
                               (handler-write-func handler))
                      (funcall (handler-write-func handler) fd)))
                  ;; TODO: add better error handling
                  (error "Handler for bad fd is present !!")))))))))
