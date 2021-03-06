;; Copyright (c) 2020 Andrey Dubovik <andrei@dubovik.eu>

;; Talking to trackers

(in-package :centrality)

(defun make-uri (host query)
  "An URI constructor that does not strive to be smart about type conversion"
  (concatenate 'string host "?"
   (string-join
    (mapcar
     (lambda (keyval)
       (destructuring-bind (key . val) keyval
       (concatenate 'string key "=" val)))
     query) "&")))

(defun split-peers (peers size)
  "Split peers array"
  (iter (for i from 0 below (length peers) by size)
        (collect (cons
                  (subseq peers i (- (+ i size) 2))
                  (unpack (subseq peers (- (+ i size) 2) (+ i size)))))))

;; TODO: add ip6 support (here and elsewhere)
(defun decode-peers (peers)
  "Decode compact tracker response (ip6 is currently ignored)"
  (let ((dict (decode-sequence peers)))
    (values (split-peers (getvalue "peers" dict) 6)
            (getvalue "interval" dict))))

(defun format-proxy (address)
  "Format proxy address for dexador"
  (if address
      (destructuring-bind (host . port) address
        (format nil "socks5://~{~d~^.~}:~d" (coerce host 'list) port))))

(define-condition non-http-tracker (error) ())

;; TODO: does dexador support username/password for SOCKS5?
(defun get-peers (tracker torrent proxy)
  "Get a list of peers from tracker"
  (if (not (equalp (subseq tracker 0 4) "http")) (error 'non-http-tracker))
  (decode-peers
   (dex:get
    (make-uri
     tracker
     `(("info_hash" . ,(quri:url-encode (tr-hash torrent)))
       ("peer_id" . ,(quri:url-encode (random-peerid)))
       ("port" . ,(write-to-string *listen-port*))
       ("uploaded" . "0")
       ("downloaded" . "0")
       ("left" . ,(write-to-string (tr-length torrent)))
       ("compact" . "1")))
    :connect-timeout *tracker-timeout*
    :read-timeout *tracker-timeout*
    :force-binary t
    :proxy (format-proxy proxy)
    :headers `(("User-Agent" . ,*user-agent*)))))

;; Tracker logic is basic: query tracker periodically, ignore errors but log them.

(defworker tracker-loop (tracker torrent control &key proxy &allow-other-keys)
  "Query tracker periodically"
  (loop
     (handler-case
         (let ((peers (get-peers tracker torrent proxy)))
           (send control :peers peers)
           (log-msg 2 :event :tracker-ok :torrent (format-hash torrent) :tracker tracker :proxy proxy :count (length peers)))
       (error (e)
         (log-msg 1 :event :tracker-fail :torrent (format-hash torrent) :tracker tracker :condition (type-of e))))
     (sleep *tracker-interval*)))
