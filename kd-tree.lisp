(in-package #:org.shirakumo.fraf.trial.space.kd-tree)

(declaim (inline sqrdist))
(defun sqrdist (a b)
  (declare (type (simple-array single-float (3)) a b))
  (+ (expt (- (aref a 0) (aref b 0)) 2)
     (expt (- (aref a 1) (aref b 1)) 2)
     (expt (- (aref a 2) (aref b 2)) 2)))

(defmacro with-array ((array vec) &body body)
  (let ((vecg (gensym "VEC")))
    `(let ((,array (make-array 3 :element-type 'single-float))
           (,vecg ,vec))
       (declare (dynamic-extent ,array))
       (etypecase ,vecg
         (vec2
          (setf (aref ,array 0) (vx2 ,vecg))
          (setf (aref ,array 1) (vy2 ,vecg)))
         (vec3
          (setf (aref ,array 0) (vx3 ,vecg))
          (setf (aref ,array 1) (vy3 ,vecg))
          (setf (aref ,array 2) (vz3 ,vecg))))
       ,@body)))

(defstruct (node
            (:constructor make-node (&optional children))
            (:copier NIL)
            (:predicate NIL))
  (near NIL :type (or null node))
  (far NIL :type (or null node))
  (children (make-array 0 :adjustable T :fill-pointer T) :type (and (vector T) (not simple-vector)))
  (axis 0 :type (unsigned-byte 8))
  (position 0.0 :type single-float)
  (tree-depth 0 :type (unsigned-byte 8)))

(defmethod print-object ((node node) stream)
  (print-unreadable-object (node stream :type T)
    (if (node-near node)
        (format stream "~[X~;Y~;Z~] ~f (~d children)"
                (node-axis node) (node-position node)
                (length (node-children node)))
        (format stream "leaf (~d children)"
                (length (node-children node))))))

(defstruct (kd-tree
            (:include container)
            (:constructor %make-kd-tree (dimensions split-size max-depth root))
            (:copier NIL)
            (:predicate NIL))
  (dimensions 0 :type (unsigned-byte 8))
  (split-size 0 :type (unsigned-byte 8))
  (max-depth 0 :type (unsigned-byte 8))
  (root NIL :type node))

(defmethod print-object ((tree kd-tree) stream)
  (print-unreadable-object (tree stream :type T)
    (format stream "~d (~d children)"
            (kd-tree-dimensions tree)
            (object-count tree))))

(defmethod describe-object ((tree kd-tree) stream)
  (call-next-method)
  (format stream "~&~%-------------------------~%")
  (describe-tree (kd-tree-root tree)
                 (lambda (node)
                   (when (node-near node)
                     (list (node-near node) (node-far node))))
                 stream))

(defun %visit-sphere (f node center radius volume)
  (declare (optimize speed (safety 1)))
  (declare (type (simple-array single-float (3)) center volume))
  (declare (type single-float radius))
  (declare (type function f))
  (declare (type node node))
  (let ((a (node-near node))
        (b (node-far node))
        (axis (node-axis node))
        (position (node-position node)))
    (funcall f node)
    (when a
      (when (< position (aref center axis))
        (rotatef a b))
      (%visit-sphere f a center radius volume)
      (let ((old (shiftf (aref volume axis) position)))
        ;; If the splitting axis is within the radius, also check the other side
        (when (< (sqrdist volume center) (* radius radius))
          (%visit-sphere f b center radius volume))
        (setf (aref volume axis) old)))))

(defun %visit-bbox (f node center bsize volume)
  (declare (optimize speed (safety 1)))
  (declare (type (simple-array single-float (3)) center bsize volume))
  (declare (type function f))
  (declare (type node node))
  (let ((a (node-near node))
        (b (node-far node))
        (axis (node-axis node))
        (position (node-position node)))
    (funcall f node)
    (when a
      (when (< position (aref center axis))
        (rotatef a b))
      (%visit-bbox f a center bsize volume)
      (let ((old (shiftf (aref volume axis) position)))
        ;; If the splitting axis is within the bounding box, also check the other side.
        (when (<= (aref bsize axis) (abs (- (aref center axis) position)))
          (%visit-bbox f b center bsize volume))
        (setf (aref volume axis) old)))))

(defun visit-sphere (f node center radius)
  (with-array (v center)
    (with-array (c center)
      (%visit-sphere f node c (float radius 0f0) v))))

(defun visit-bbox (f node center bsize)
  (with-array (v center)
    (with-array (c center)
      (with-array (b bsize)
        (%visit-bbox f node c b v)))))

(defun split-node-axis (node children axis other-axes split-size)
  (declare (optimize speed (safety 1)))
  (declare (type (unsigned-byte 8) axis split-size))
  (declare (type node node))
  (declare (type (and (vector T) (not simple-vector)) children))
  (let ((dim-value (ecase axis
                     (0 (lambda (o) (vx (location o))))
                     (1 (lambda (o) (vy (location o))))
                     (2 (lambda (o) (vz (location o))))))
        (dim-extr (ecase axis
                    (0 #'vx)
                    (1 #'vy)
                    (2 #'vz))))
    (declare (type (function (T) single-float) dim-value dim-extr))
    (sort children #'< :key dim-value)
    (let* ((mid (truncate (length children) 2))
           (median (if (oddp (length children))
                       (funcall dim-value (aref children mid))
                       (* 0.5 (/ (funcall dim-value (aref children (+ mid 0)))
                                 (funcall dim-value (aref children (+ mid 1))))))))
      ;; Okey, now redistribute.
      (let ((near (make-array split-size :adjustable T :fill-pointer 0))
            (far (make-array split-size :adjustable T :fill-pointer 0))
            (here (node-children node)))
        (setf (fill-pointer here) 0)
        (loop for child across children
              for location = (funcall dim-extr (location child))
              do (cond ((< (abs (- location median)) (funcall dim-extr (bsize child)))
                        ;; We intersect the hyperplane, so keep it here.
                        (vector-push child here))
                       ((< location median)
                        (vector-push-extend child near))
                       (T
                        (vector-push-extend child far))))
        (cond ((/= (length here) (length children))
               ;; We split successfully, actually modify the node now.
               (incf (node-tree-depth node))
               (setf (node-axis node) axis)
               (setf (node-position node) median)
               (setf (node-near node) (make-node near))
               (setf (node-far node) (make-node far))
               (setf (node-children node) here))
              (other-axes
               ;; We failed to split and arrived at the initial state. Try another axis.
               (setf axis (pop other-axes))
               (split-node-axis node children axis other-axes split-size))
              (T
               ;; No other axes available, mark node as stuck.
               (setf (node-position node) most-negative-single-float)))))))

(defun split-node (node dims split-size)
  ;; TODO: specialise on DIMS so we can use VX2 / VX3 etc
  (declare (optimize speed (safety 1)))
  (declare (type (unsigned-byte 8) split-size dims))
  (declare (type node node))
  (unless (= most-negative-single-float (node-position node))
    (let* ((children (node-children node))
           (children (make-array (max split-size (length children))
                                 :adjustable T :fill-pointer (length children)
                                 :initial-contents children))
           (min 0.0) (max 0.0) (max-range 0.0) (max-dim 0) (others ()))
      (declare (type single-float min max max-range))
      ;; Figure out widest spread axis
      (dotimes (axis dims)
        (loop with accessor = (ecase axis
                                (0 #'vx) (1 #'vy) (2 #'vz))
              for child across children
              for loc = (the single-float (funcall accessor (location child)))
              for siz = (the single-float (funcall accessor (bsize child)))
              do (setf min (min min (- loc siz)))
                 (setf max (max max (+ loc siz))))
        (cond ((< max-range (- max min))
               (setf max-range (- max min))
               (setf max-dim axis))
              (T
               (push axis others))))
      ;; Try to split the node along the best axis.
      (split-node-axis node children max-dim others split-size))))

(defun recompute-subtree (node max-depth split-size dims)
  ;; TODO: recompute this subtree
  )

(defun kd-tree-insert (object tree)
  (declare (optimize speed (safety 1)))
  (let ((dims (kd-tree-dimensions tree))
        (max-depth (kd-tree-max-depth tree))
        (split-size (kd-tree-split-size tree)))
    (with-array (v (location object))
      (with-array (c (location object))
        (with-array (b (bsize object))
          (flet ((check (node)
                   (let ((axis (node-axis node)))
                     (when (or (null (node-near node))
                               (<= (abs (- (aref c axis) (node-position node))) (aref b axis)))
                       ;; We are intersecting the hyperplane, so insert here.
                       (vector-push-extend object (node-children node))
                       (cond ((< (length (node-children node)) split-size))
                             ;; Node is overfull, split it if we can.
                             ((and (< (node-tree-depth node) max-depth)
                                   (null (node-near node)))
                              (split-node node dims split-size))
                             ;; We should split, but are not leaf.
                             ((< (node-tree-depth node) max-depth)
                              (recompute-subtree node max-depth split-size dims)))
                       (return-from kd-tree-insert)))))
            (declare (dynamic-extent #'check))
            (%visit-bbox #'check (kd-tree-root tree) c b v)))))))

(declaim (inline transfer-node))
(defun transfer-node (source target)
  (declare (optimize speed (safety 1)))
  (declare (type node source target))
  (setf (node-near target) (node-near source))
  (setf (node-far target) (node-far source))
  (setf (node-children target) (node-children source))
  (setf (node-axis target) (node-axis source))
  (setf (node-position target) (node-position source))
  (setf (node-tree-depth target) (node-tree-depth source)))

(defun kd-tree-remove (object tree)
  (declare (optimize speed (safety 1)))
  (with-array (v (location object))
    (with-array (c (location object))
      (with-array (b (bsize object))
        (flet ((check (node)
                 (let ((axis (node-axis node)))
                   (when (<= (abs (- (aref c axis) (node-position node))) (aref b axis))
                     ;; We are intersecting the hyperplane, so we may reside here here.
                     (let* ((children (node-children node))
                            (pos (position object children)))
                       (when pos
                         (loop for i from pos below (1- (length children))
                               do (setf (aref children i) (aref children (1+ i))))
                         (when (node-near node)
                           ;; Since we changed this node, let's see if we can collapse it, too.
                           ;; Though this kinda sucks, since ideally we'd aggressively collapse
                           ;; when the child becomes empty. We can't do that, though, since the
                           ;; child has no way to signal to the parent that it should collapse
                           ;; without also storing another back link.
                           (let ((near-empty (= 0 (length (node-children (node-near node)))))
                                 (far-empty (= 0 (length (node-children (node-far node))))))
                             (cond ((and near-empty far-empty)
                                    ;; Both our children are worthless, so become a leaf.
                                    (setf (node-near node) NIL)
                                    (setf (node-far node) NIL)
                                    (setf (node-tree-depth node) 0))
                                   ((< 0 (length children)))
                                   (near-empty
                                    ;; We are empty, so we can become the far node.
                                    (transfer-node (node-far node) node))
                                   (far-empty
                                    ;; We are empty, so we can become the near node.
                                    (transfer-node (node-near node) node)))))
                         (return-from kd-tree-remove)))))))
          (declare (dynamic-extent #'check))
          (%visit-bbox #'check (kd-tree-root tree) c b v))))))

(defun make-kd-tree (&key (dimensions 3) (split-size 8) (max-depth 255))
  (assert (<= 1 dimensions 3))
  (assert (< 1 split-size))
  (assert (< max-depth 256))
  (%make-kd-tree dimensions split-size max-depth (make-node)))

(defmethod clear ((tree kd-tree))
  (setf (kd-tree-root tree) (make-node))
  tree)

(defmethod reoptimize ((tree kd-tree) &key)
  (recompute-subtree (kd-tree-root tree) (kd-tree-max-depth tree) (kd-tree-split-size tree) (kd-tree-dimensions tree))
  tree)

(defmethod enter (object (tree kd-tree))
  (kd-tree-insert object tree))

(defmethod leave (object (tree kd-tree))
  (kd-tree-remove object tree))

(defmethod call-with-all (function (tree kd-tree))
  (declare (optimize speed (safety 1)))
  (let ((stack (make-array 0 :adjustable T :fill-pointer T))
        (function (etypecase function
                    (function function)
                    (symbol (fdefinition function)))))
    (declare (dynamic-extent stack))
    (vector-push-extend (kd-tree-root tree) stack)
    (loop for node = (vector-pop stack)
          do (loop for i across (node-children node)
                   do (funcall function i))
             (when (node-near node)
               (vector-push-extend (node-near node) stack))
             (when (node-far node)
               (vector-push-extend (node-far node) stack))
          while (< 0 (length stack)))))

(defmethod call-with-overlapping (function (tree kd-tree) (region region))
  (declare (optimize speed (safety 1)))
  (with-array (c region)
    (with-array (b (region-size region))
      (let ((v (make-array 3 :element-type 'single-float))
            (function (etypecase function
                        (function function)
                        (symbol (fdefinition function)))))
        (declare (dynamic-extent v))
        (setf (aref v 0) (incf (aref c 0) (setf (aref b 0) (* 0.5 (aref b 0)))))
        (setf (aref v 1) (incf (aref c 1) (setf (aref b 1) (* 0.5 (aref b 1)))))
        (setf (aref v 2) (incf (aref c 2) (setf (aref b 2) (* 0.5 (aref b 2)))))
        (flet ((visit (node)
                 (loop for child across (node-children node)
                       do (funcall function child))))
          (declare (dynamic-extent #'visit))
          (%visit-bbox #'visit (kd-tree-root tree) c b v))))))

(defmethod call-with-overlapping (function (tree kd-tree) (sphere sphere))
  (declare (optimize speed (safety 1)))
  (with-array (c sphere)
    (let ((v (make-array 3 :element-type 'single-float))
          (function (etypecase function
                      (function function)
                      (symbol (fdefinition function)))))
      (declare (dynamic-extent v))
      (setf (aref v 0) (aref c 0))
      (setf (aref v 1) (aref c 1))
      (setf (aref v 2) (aref c 2))
      (flet ((visit (node)
               (loop for child across (node-children node)
                     do (funcall function child))))
        (declare (dynamic-extent #'visit))
        (%visit-sphere #'visit (kd-tree-root tree) c (sphere-radius sphere) v)))))

(defmethod call-with-intersecting (function (tree kd-tree) ray-origin ray-direction)
  (declare (optimize speed (safety 1)))
  (with-array (o ray-origin)
    (with-array (d ray-direction)
      (let ((function (etypecase function
                        (function function)
                        (symbol (fdefinition function)))))
        (labels ((visit (node tmax)
                   (declare (type node node))
                   (declare (type single-float tmax))
                   (let ((a (node-near node))
                         (b (node-far node))
                         (axis (node-axis node))
                         (position (node-position node)))
                     (loop for child across (node-children node)
                           do (funcall function child))
                     (when a
                       (when (< position (aref o axis))
                         (rotatef a b))
                       (if (= 0.0 (aref d axis))
                           (visit a tmax)
                           (let ((tt (/ (- position (aref o axis)) (aref d axis))))
                             (cond ((and (<= 0.0 tt) (< tt tmax))
                                    (visit a tt)
                                    (let ((ox (aref o 0)) (oy (aref o 1)) (oz (aref o 2)))
                                      (incf (aref o 0) (* tt (aref d 0)))
                                      (incf (aref o 1) (* tt (aref d 1)))
                                      (incf (aref o 2) (* tt (aref d 2)))
                                      (visit b (- tmax tt))
                                      (setf (aref o 0) ox)
                                      (setf (aref o 1) oy)
                                      (setf (aref o 2) oz)))
                                   (T
                                    (visit a tmax)))))))))
          (visit (kd-tree-root tree) most-positive-single-float))))))

(defun kd-tree-call-with-nearest (function location tree)
  (declare (optimize speed (safety 1)))
  (let ((function (etypecase function
                    (function function)
                    (symbol (fdefinition function)))))
    (with-array (v location)
      (with-array (c location)
        (let ((radius most-positive-single-float))
          (declare (type single-float radius))
          (labels ((visit (node)
                     (let ((a (node-near node))
                           (b (node-far node))
                           (axis (node-axis node))
                           (position (node-position node)))
                       (loop for child across (node-children node)
                             for distance = (with-array (l (location child))
                                              (sqrdist c l))
                             do (when (< distance radius)
                                  (setf radius (funcall function child distance))))
                       (when a
                         (when (< position (aref c axis))
                           (rotatef a b))
                         (visit a)
                         (let ((old (shiftf (aref v axis) position)))
                           (when (< (sqrdist v c) (* radius radius))
                             (visit b))
                           (setf (aref v axis) old))))))
            (visit (kd-tree-root tree))))))))

(defun kd-tree-nearest (location tree &optional reject)
  (declare (optimize speed (safety 1)))
  (let ((radius most-positive-single-float)
        (candidate NIL))
    (flet ((visit (object distance)
             (unless (eq object reject)
               (setf candidate object)
               (setf radius distance))
             radius))
      (declare (dynamic-extent #'visit))
      (kd-tree-call-with-nearest #'visit location tree)
      candidate)))

(defun kd-tree-k-nearest (k location tree &key test)
  (declare (optimize speed (safety 1)))
  (check-type k (and (integer 1) (unsigned-byte 32)))
  (let* ((max-i (1- k))
         (candidates (make-array k :element-type T :initial-element NIL))
         (distances (make-array k :element-type 'single-float :initial-element most-positive-single-float))
         (test (etypecase test
                 (null (constantly T))
                 (function test)
                 (symbol (fdefinition test))))
         (found 0))
    (declare (type (unsigned-byte 32) max-i found))
    (flet ((visit (candidate distance)
             (declare (type single-float distance))
             (when (and (< distance (aref distances max-i))
                        (funcall test candidate))
               ;; Sorted insertion to ensure that we keep track of the k nearest.
               ;; TODO: I feel like this might be better if we had a doubly linked
               ;;       list instead, since then we could insert more efficiently?
               (incf found)
               (loop for i of-type (unsigned-byte 32) downfrom max-i above 0
                     do (cond ((< distance (aref distances (1- i)))
                               (setf (aref distances i) (aref distances (1- i))
                                     (aref candidates i) (aref candidates (1- i))))
                              (T
                               (setf (aref distances i) distance
                                     (aref candidates i) candidate)
                               (return)))
                     finally (setf (aref distances 0) distance
                                   (aref candidates 0) candidate)))
             (aref distances max-i)))
      (declare (dynamic-extent #'visit))
      (kd-tree-call-with-nearest #'visit location tree)
      (values candidates (min (length candidates) found)))))
