(require :robot-interface "package://pr2eus/robot-interface.l")

(ros::load-ros-manifest "dynamic_reconfigure")
(ros::roseus-add-msgs "hrpsys_ros_bridge")
(ros::load-ros-manifest "hrpsys_ros_bridge")

(defclass rtm-ros-robot-interface
  :super robot-interface
  :slots ()
  )

(defmethod rtm-ros-robot-interface
  (:init
   (&rest args)
   (prog1
       (send-super* :init args)
     (send self :define-all-ROSBridge-srv-methods)
     (ros::subscribe "/motor_states" hrpsys_ros_bridge::MotorStates
                     #'send self :rtmros-motor-states-callback :groupname groupname)
     (mapcar #'(lambda (x)
                 (ros::subscribe (format nil "/~A" (string-downcase x)) geometry_msgs::WrenchStamped
                                 #'send self :rtmros-force-sensor-callback x :groupname groupname)
                 (ros::subscribe (format nil "/off_~A" (string-downcase x)) geometry_msgs::WrenchStamped
                                 #'send self :rtmros-force-sensor-callback (read-from-string (format nil ":off-~A" (string-downcase x))) :groupname groupname))
             (send-all (send robot :force-sensors) :name))
     (ros::subscribe "/zmp" geometry_msgs::PointStamped
                     #'send self :rtmros-zmp-callback :groupname groupname)

     ))
  (:rtmros-motor-states-callback
   (msg)
   (send self :set-robot-state1 :motor-extra-data (send msg :extra_data))
   (send self :set-robot-state1 :temperature (send msg :temperature)))
  (:rtmros-zmp-callback
   (msg)
   (let ((p (send msg :point)))
     (send self :set-robot-state1 :zmp (float-vector (send p :x) (send p :y) (send p :z)))))
  (:temperature-vector () (cdr (assoc :temperature robot-state)))
  (:motor-extra-data
   ()
   (let* ((d (cdr (assoc :motor-extra-data robot-state)))
          (dims (mapcar #'(lambda (x) (send x :size)) (send (send d :layout) :dim)))
          (ret))
     (dotimes (j (car dims))
       (push (subseq (send d :data) (* j (cadr dims)) (* (1+ j) (cadr dims))) ret))
     (reverse ret)))
  (:rtmros-force-sensor-callback
   (fsensor-name msg)
   (let ((wrc (send msg :wrench)))
     (send self :set-robot-state1 fsensor-name
           (float-vector (send (send wrc :force) :x)
                         (send (send wrc :force) :y)
                         (send (send wrc :force) :z)
                         (send (send wrc :torque) :x)
                         (send (send wrc :torque) :y)
                         (send (send wrc :torque) :z)))))
  (:tmp-force-moment-vector
   (f/m &optional (limb) (off nil))
   (if limb
       (let ((key-name (if off
                           (read-from-string (format nil ":~A-~A" off (string-downcase (send (send robot :force-sensor limb) :name))))
                         (send (send robot :force-sensor limb) :name))))
         (subseq (cdr (assoc key-name robot-state))
                 (if (eq f/m :force) 0 3)
                 (if (eq f/m :force) 3 6)))
     (mapcar #'(lambda (x)
                 (send self :tmp-force-moment-vector f/m x off))
             (send-all (send robot :force-sensors) :name))))
  (:force-vector
   (&optional (limb))
   (send self :tmp-force-moment-vector :force limb))
  (:moment-vector
   (&optional (limb))
   (send self :tmp-force-moment-vector :moment limb))
  (:off-force-vector
   (&optional (limb))
   (send self :tmp-force-moment-vector :force limb "off"))
  (:off-moment-vector
   (&optional (limb))
   (send self :tmp-force-moment-vector :moment limb "off"))
  (:absolute-force-vector
   (&optional (limb))
   (if limb
       (send (send robot :force-sensor limb) :rotate-vector (send self :off-force-vector limb))
     (mapcar #'(lambda (fs force)
                 (send fs :rotate-vector force))
             (send robot :force-sensors) (send self :off-force-vector))))
  (:absolute-moment-vector
   (&optional (limb))
   (if limb
       (send (send robot :force-sensor limb) :rotate-vector (send self :off-moment-vector limb))
     (mapcar #'(lambda (fs moment)
                 (send fs :rotate-vector moment))
             (send robot :force-sensors) (send self :off-moment-vector))))
  (:zmp-vector
   (&optional (wrt :local))
   (let ((zmp (scale 1e3 (cdr (assoc :zmp robot-state)))))
     (case wrt
       (:local zmp)
       (:world (send (car (send robot :links)) :transform-vector zmp)))))
  ;; automatically define methods for ROSBridge services
  (:define-all-ROSBridge-srv-methods
   (&key (debug-view nil) (ros-pkg-name "hrpsys_ros_bridge"))
   (let ((srv-fnames (send self :get-ROSBridge-srv-fnames ros-pkg-name)))
     (dolist (idl (send self :get-ROSBridge-idl-fnames ros-pkg-name))
       (let ((rtc-name (pathname-name idl)))
         (dolist (srv-name (mapcar #'pathname-name (remove-if-not #'(lambda (x) (and (substringp rtc-name x) (not (= (char x 0) (char "." 0))))) srv-fnames)))
           (let ((method-def (send self :get-ROSBridge-method-def-macro rtc-name srv-name)))
             (when method-def
               (if debug-view (pprint (macroexpand method-def)))
               (eval method-def)
               )))))))
  (:get-ROSBridge-fnames-from-type
   (type-name &optional (ros-pkg-name "hrpsys_ros_bridge"))
   (let ((path (ros::resolve-ros-path (format nil "package://~A" ros-pkg-name))))
     (remove-if-not #'(lambda (x) (substringp (format nil ".~A" type-name) x)) (directory (format nil "~A/~A" path type-name)))
     ))
  (:get-ROSBridge-idl-fnames (&optional (ros-pkg-name "hrpsys_ros_bridge")) (send self :get-ROSBridge-fnames-from-type "idl" ros-pkg-name))
  (:get-ROSBridge-srv-fnames (&optional (ros-pkg-name "hrpsys_ros_bridge")) (send self :get-ROSBridge-fnames-from-type "srv" ros-pkg-name))
  (:get-ROSBridge-method-def-macro
   (rtc-name srv-name)
   (let* ((meth-name (string-left-trim "_" (string-left-trim rtc-name (string-left-trim "_" (string-left-trim "OpenHRP" srv-name)))))
          (srv-request (read-from-string (format nil "hrpsys_ros_bridge::~ARequest" srv-name)))
          (init-method (find-if #'(lambda (x) (eq (car x) :init)) (send (eval srv-request) :methods)))
          ;;(new-method-name (read-from-string (format nil ":~A" (string-left-trim "_" (string-left-trim rtc-name (string-left-trim "_" (string-left-trim "OpenHRP" srv-name))))))))
          (new-method-name (read-from-string (format nil ":~A" (string-left-trim "_" (string-left-trim "OpenHRP" srv-name))))))
     (if (find-method self new-method-name)
         (progn
           (warn ";; Method conflict in ROSBridge defmethod!! ;; ~A~%" srv-name)
           nil)
       `(defmethod rtm-ros-robot-interface
          (,new-method-name
           ,(cadr init-method)
           (ros::service-call
            ,(format nil "/~AROSBridge/~A" rtc-name meth-name)
            (instance ,(eval srv-request) :init ,@(mapcan #'(lambda (x) (list (caar x) (cadar x))) (cdadr init-method))))
           )
          )
       )))
  ;;
  (:sendmsg
   (strs &optional (service-name "sendmsg"))
   (ros::service-call
    service-name
    (let ((req (instance dynamic_reconfigure::ReconfigureRequest :init)))
      (send (send req :config) :strs
	    (mapcar #'(lambda (str)
			(instance dynamic_reconfigure::StrParameter :init :name service-name :value str))
		    strs))
      req)))
  (:set-interpolation-mode (mode) (send self :sendmsg (list "setInterpolationMode" (format nil "~A" mode))))
  ;; just for seq debug
  (:wait-interpolation-for-seq-debug () (send self :sendmsg (list "waitInterpolation" "")))
  (:angle-vector-for-seq-debug
   (v tm)
   (send self :sendmsg
	 (list "setJointAngles"
	       (let ((str""))
		 (dotimes (i (length v)) (setq str (format nil "~A ~A" str (deg2rad (elt v i)))))
		 (format nil "~A ~A" str (* 1e-3 tm))))))
  ;; dump pattern file for SequencePlayer
  ;;  rs-list : list of (list :time time0 :angle-vector av :root-coords rc ...)
  ;;  output-basename : output file (output-basename.pos, ...)
  (:dump-seq-pattern-file
   (rs-list output-basename &key (initial-sync-time 3.0)) ;; [s]
   (warn ";; :dump-seq-pattern-file is deprecated!! Please use (dump-seq-pattern-file) funciton!!~%")
   (dump-seq-pattern-file rs-list output-basename :initial-sync-time initial-sync-time)
   )
  ;;
  (:update-robot-state
   ()
   (send-super :update-robot-state)
   (let ((imucoords (send *tfl* :lookup-transform "/imu_floor" (format nil "/~a" (send (car (send robot :links)) :name)) (ros::time))))
     (if imucoords (send robot :newcoords imucoords))
     ))
  (:imucoords
   ()
   (send robot :copy-worldcoords))
  (:state
    (&rest args)
    (case (car args)
      (:imucoords
       (send-super* :state args)
       (send self :imucoords))
      (t
       (send-super* :state args))))
  ;; Calculate zmp from state [mm]
  ;; example ;; (progn (send *ri* :go-velocity 0 0 0) (objects (list (*ri* . robot))) (do-until-key (let ((zmp (send *ri* :calc-zmp-from-state))) (send *irtviewer* :draw-objects :flush nil) (send zmp :draw-on :flush t :size 300))))
  (:calc-zmp-from-state
   (&key (wrt :world))
   ;; :wrt is :local => calc local zmp for (*ri* . robot)'s root-link coords
   ;; :wrt is :world => calc world zmp for (*ri* . robot)
   (send self :state)
   (send robot :calc-zmp-from-forces-moments
         (mapcar #'(lambda (x) (send self :force-vector x)) '(:rleg :lleg))
         (mapcar #'(lambda (x) (send self :moment-vector x)) '(:rleg :lleg))
         :wrt wrt)
   )
  )

;; SequencePlayerService
(defmethod rtm-ros-robot-interface
  (:set-base-pose
   (&optional base-coords (tm 0.1))
   (unless base-coords
     (setq base-coords (send robot :worldcoords)))
   (send self :sequenceplayerservice_setbasepos :pos (scale 0.001 (send base-coords :pos)) :tm tm)
   (send self :sequenceplayerservice_setbaserpy :rpy (coerce (reverse (car (send base-coords :rpy-angle))) float-vector) :tm tm))
  (:wait-interpolation-of-group
   (groupname)
   (send self :sequenceplayerservice_waitinterpolationofgroup :gname groupname))
  (:add-joint-group
   (groupname jnames)
   (send self :sequenceplayerservice_addjointgroup :gname groupname :jnames jnames))
  (:remove-joint-group
   (groupname)
   (send self :sequenceplayerservice_removejointgroup :gname groupname))
  (:set-joint-angles-of-group
   (groupname av tm)
   (send self :sequenceplayerservice_setjointanglesofgroup :gname groupname :jvs av :tm tm))
  (:load-pattern (basename &optional (tm 0.0)) (send self :sequenceplayerservice_loadpattern :basename basename :tm tm))
#| ;; angle group sample
  (send *ri* :add-joint-group "larm" (send-all (send *robot* :larm :joint-list) :name))
  (send *ri* :set-jointangles-of-group "larm" (scale (/ pi 180.0) (send *robot* :larm :angle-vector)) 4.0)
  (send *ri* :waitinterpolation-of-group "larm")
|#
  )

;; CollisionDetectorService
(defmethod rtm-ros-robot-interface
  (:set-tolerance
   (&key (tolerance 0.1) (link-pair-name "all"))
   (send self :collisiondetectorservice_settolerance
         :link_pair_name link-pair-name :tolerance tolerance))
  (:start-collision-detection
   ()
   (send self :collisiondetectorservice_enablecollisiondetection))
  (:stop-collision-detection
   ()
   (send self :collisiondetectorservice_disablecollisiondetection))
  ;; deprecated
  (:enableCollisionDetection
   ()
   (warning-message 1 ";; :enableCollisionDetection is deprecated!! Please use :start-collision-detection!!~%")
   (send self :start-collision-detection))
  (:disableCollisionDetection ()
   (warning-message 1 ";; :disableCollisionDetection is deprecated!! Please use :stop-collision-detection!!~%")
   (send self :stop-collision-detection))
  )

;; DataLoggerService
(defmethod rtm-ros-robot-interface
  (:save-log (fname) (send self :dataloggerservice_save :basename fname))
  ;; start log by clearing log
  (:start-log () (send self :dataloggerservice_clear))
  (:set-log-maxlength
   (&optional (maxlength 4000))
   (send self :dataloggerservice_maxlength :len maxlength))
  )

;; RobotHardwareService
(defmethod rtm-ros-robot-interface
  (:set-servo-gain-percentage
   (name percentage)
   (send self :robothardwareservice_setservogainpercentage :name name :percentage percentage))
  (:remove-force-sensor-offset () (send self :robothardwareservice_removeforcesensoroffset))
  (:set-servo-error-limit
    (name limit)
    (send self :robothardwareservice_setservoerrorlimit :name name :limit limit)
    )
  ;; deprecated
  (:setServoGainPercentage
   (name percentage)
   (warning-message 1 ";; :setServoGainPercentage is deprecated!! Please use :set-servo-gain-percentage!!~%")
   (send self :set-servo-gain-percentage name percentage))
  )

;; ImpedanceControllerService
(defmethod rtm-ros-robot-interface
  ;;
  ;; usage:
  ;;   (send *ri* :start-impedance :rarm ..), (send *ri* :stop-impedance :rarm ..), (send *ri* :set-impedance-controller-param :rarm :M-p 200) ...
  ;;
  ;; set impedance controller param
  ;;   params other than user-defined params are used in current parameter in ImpedanceController RTC by using getImpedanceControllerParam
  ;;   original default parameters are defined in hrpsys-base/rtc/ImpedanceController/ImpedancControl.h
  (:_set-impedance-controller-param
   (&key name base-name target-name
         M-p D-p K-p
         M-r D-r K-r
         ref-force ref-moment
         force-gain moment-gain
         sr-gain avoid-gain reference-gain manipulability-limit)
   (let* ((current-imp-param (send self :get-impedance-controller-param name))
          (param (instance hrpsys_ros_bridge::OpenHRP_ImpedanceControllerService_impedanceParam :init
                            :name name :base_name base-name :target_name target-name
                            :M_p (if M-p M-p (send current-imp-param :M_p))
                            :D_p (if D-p D-p (send current-imp-param :D_p))
                            :K_p (if K-p K-p (send current-imp-param :K_p))
                            :M_r (if M-r M-r (send current-imp-param :M_r))
                            :D_r (if D-r D-r (send current-imp-param :D_r))
                            :K_r (if K-r K-r (send current-imp-param :K_r))
                            :ref_force (if ref-force ref-force (send current-imp-param :ref_force))
                            :ref_moment (if ref-moment ref-moment (send current-imp-param :ref_moment))
                            :force_gain (if force-gain force-gain (send current-imp-param :force_gain))
                            :moment_gain (if moment-gain moment-gain (send current-imp-param :moment_gain))
                            :sr_gain (if sr-gain sr-gain (send current-imp-param :sr_gain))
                            :avoid_gain (if avoid-gain avoid-gain (send current-imp-param :avoid_gain))
                            :reference_gain (if reference-gain reference-gain (send current-imp-param :reference_gain))
                            :manipulability_limit (if manipulability-limit manipulability-limit (send current-imp-param :manipulability_limit)))))
     (send self :impedancecontrollerservice_setimpedancecontrollerparam :i_param param)))
  (:start-impedance
   (limb &rest args)
   (send* self :set-impedance-controller-param limb args))
  (:stop-impedance
   (limb)
   (send self :force-sensor-method
         limb
         #'(lambda (name base-name target-name &rest _args)
             (send self :impedancecontrollerservice_deleteimpedancecontroller :name name))
         :stop-impedance))
  (:set-impedance-controller-param
   (limb &rest args)
   (send* self :force-sensor-method
         limb
         #'(lambda (name base-name target-name &rest _args)
             (send* self :_set-impedance-controller-param
                    :name name
                    :base-name base-name
                    :target-name target-name _args))
         :set-impedance-controller-param
         args))
  (:get-impedance-controller-param
   (limb)
   (send self :force-sensor-method
         limb
         #'(lambda (name base-name target-name &rest _args)
             (send (send self :impedancecontrollerservice_getimpedancecontrollerparam :name name) :i_param))
         :get-impedance-controller-param))
  (:force-sensor-method
   (limb method-func method-name &rest args)
   (cond
    ((stringp limb)
     (apply method-func
            limb nil nil args))
    ((send robot :force-sensor limb)
     (let ((fs (send robot :force-sensor limb))
           (base-name (send (send (send (send robot limb :root-link) :parent) :joint) :name)))
       (apply method-func
              (string-downcase (send fs :name))
              (if base-name base-name "")
              (send (send (send fs :parent) :joint) :name)
              args)))
    ((and (substringp ":v" (format nil "~A" limb))
          (find-method robot (read-from-string (format nil ":~A" (string-left-trim ":v" (format nil "~A" limb))))))
     (let ((rlimb (read-from-string (format nil ":~A" (string-left-trim ":v" (format nil "~A" limb))))))
       (apply method-func
              (format nil "v~C~A" (elt (string-left-trim ":v" (format nil "~A" limb)) 0) (case rlimb ((:rarm :larm) "hsensor") (t "fsensor")))
              (send (send (send (send robot rlimb :root-link) :parent) :joint) :name)
              (send (send (send (send robot rlimb :end-coords) :parent) :joint) :name)
              args)))
    ((eq limb :legs) (mapcar #'(lambda (l) (send* self method-name l args)) '(:rleg :lleg)))
    ((eq limb :arms) (mapcar #'(lambda (l) (send* self method-name l args)) '(:rarm :larm)))
    (t ) ;; virtual force sensor is not supported in this file
    ))
  )

;; AbsoluteForceSensorService
(defmethod rtm-ros-robot-interface
  (:_set-forcemoment-offset-param
   (name &key force-offset moment-offset link-offset-centroid link-offset-mass)
   (let* ((current-fm-param (send self :get-forcemoment-offset-param name))
          (param (instance hrpsys_ros_bridge::OpenHRP_AbsoluteForceSensorService_ForceMomentOffsetParam :init
                           :force_offset (if force-offset force-offset (send current-fm-param :force_offset))
                           :moment_offset (if moment-offset moment-offset (send current-fm-param :moment_offset))
                           :link_offset_centroid (if link-offset-centroid link-offset-centroid (send current-fm-param :link_offset_centroid))
                           :link_offset_mass (if link-offset-mass link-offset-mass (send current-fm-param :link_offset_mass)))))
     (send self :absoluteforcesensorservice_setforcemomentoffsetparam :name name :i_param param)))
  (:set-forcemoment-offset-param
   (limb &rest args)
   (send* self :force-sensor-method
         limb
         #'(lambda (name base-name target-name &rest _args)
             (send* self :_set-forcemoment-offset-param name _args))
         :set-forcemoment-offset-param
         args))
  (:get-forcemoment-offset-param
   (limb)
   (send self :force-sensor-method
         limb
         #'(lambda (name base-name target-name &rest _args)
             (send (send self :absoluteforcesensorservice_getforcemomentoffsetparam :name name) :i_param))
         :get-forcemoment-offset-param))
  (:load-forcemoment-offset-param
   (fname &key (set-offset t))
   (mapcar #'(lambda (x)
               (send* self :set-forcemoment-offset-param (car x)
                      (if set-offset
                          (cdr x)
                        (list :link-offset-mass (cadr (memq :link-offset-mass (cdr x)))
                              :link-offset-centroid (cadr (memq :link-offset-centroid (cdr x)))))))
           (with-open-file
            (f fname :direction :input)
            (read f nil nil)))
   )
  (:reset-force-moment-offset-arms
   ()
   (send self :reset-force-moment-offset '(:rarm :larm)))
  (:reset-force-moment-offset
   (limbs)
   (send self :_reset-force-moment-offset limbs :force)
   (send self :_reset-force-moment-offset limbs :moment)
   )
  (:_reset-force-moment-offset
   (limbs f/m &key (itr 10))
   ;; f_ext = Rs * (s^f_s - s^f_off) - m_l * g
   ;; n_ext = Rs * (s^n_s - s^n_off) - (Rs * c_l) x (m_l * g)
   ;; s^f_off = s^f_s - Rs^T * (f_ext + m_l * g)
   ;; s^n_off = s^n_s - Rs^T * (n_ext + (Rs * c_l) x (m_l * g))
   (labels ((calc-off
             (alimb)
             (unix:usleep 10000)
             (send self :state)
             (let* ((abs-v (send self (read-from-string (format nil ":absolute-~A-vector" (string-downcase f/m))) alimb))
                    (param (send self :get-forcemoment-offset-param alimb))
                    (off (v+ (send param (if (eq f/m :force) :force_offset :moment_offset))
                             (send (send robot :force-sensor alimb) :inverse-rotate-vector abs-v))))
               (list off abs-v))))
     (mapcar #'(lambda (alimb)
                 (let* ((ret (mapcar #'(lambda (x) (calc-off alimb)) (make-list itr)))
                        (off (mapcar #'car ret))
                        (abs-v (mapcar #'cadr ret)))
                   (send self :set-forcemoment-offset-param alimb
                         (if (eq f/m :force) :force-offset :moment-offset)
                         (scale (/ 1.0 (length off)) (reduce #'v+ off)))
                   (unix:usleep 10000)
                   ;; check ;; compare sensor value before & after resetting
                   (format t ";; ~A error of ~A ;; ~A[~A] -> ~A[~A]~%"
                           (string-downcase f/m) alimb
                           (norm (scale (/ 1.0 (length abs-v)) (reduce #'v+ abs-v)))
                           (if (eq f/m :force) "N" "Nm")
                           (norm
                            (scale (/ 1.0 itr)
                                   (reduce #'v+
                                           (mapcar #'(lambda (x) (send self :state (read-from-string (format nil ":absolute-~A-vector" (string-downcase f/m))) alimb))
                                                   (make-list itr)))))
                           (if (eq f/m :force) "N" "Nm"))
                   ))
             limbs)))
  )

;; AutoBalancerService
(defmethod rtm-ros-robot-interface
  (:start-auto-balancer
   (&key (limbs '(:rleg :lleg)))
   (send self :autobalancerservice_startABC
         :alp (mapcar #'(lambda (limb)
                          (let ((target2foot (send (send (send robot limb :end-coords) :parent) :transformation (send robot limb :end-coords))))
                            (instance hrpsys_ros_bridge::openhrp_autobalancerservice_autobalancerlimbparam
                                      :init :name (format nil "~A" limb)
                                      ;;:target_name (send (send (send robot limb :end-coords) :parent) :joint :name)
                                      ;;:base_name (if (send (send (send robot limb :root-link) :parent) :joint) (send (send (send robot limb :root-link) :parent) :joint :name) "WAIST")
                                      :target2foot_offset_pos (scale 1e-3 (send target2foot :worldpos))
                                      :target2foot_offset_rot (matrix2quaternion (send target2foot :worldrot)))))
                      limbs)))
  (:stop-auto-balancer () (send self :autobalancerservice_stopABC))
  (:go-pos-no-wait
   (xx yy th)
   (send self :autobalancerservice_goPos :x xx :y yy :th th))
  (:go-pos
   (xx yy th)
   (send self :go-pos-no-wait xx yy th)
   (send self :wait-foot-steps))
  (:get-foot-step-param
   ()
   (send (send self :autobalancerservice_getfootstepparam) :i_param)
   )
  (:set-foot-steps-no-wait
   (fs)
   (let ((init-coords
          (midcoords 0.5
                     (send self :abc-footstep->eus-footstep (send (send self :get-foot-step-param) :rleg_coords))
                     (send self :abc-footstep->eus-footstep (send (send self :get-foot-step-param) :lleg_coords)))))
     (send self :autobalancerservice_setfootsteps
           :fs
           (mapcar #'(lambda (f)
                       (let ((lf (send (send init-coords :copy-worldcoords)
                                       :transform f)))
                         (send lf :put :l/r (send f :get :l/r))
                         (send self :eus-footstep->abc-footstep lf)))
                   fs))
     ))
  (:set-foot-steps
   (fs)
   (send self :set-foot-steps-no-wait fs)
   (send self :wait-foot-steps))
  (:go-velocity
   (vx vy vth)
   (send self :autobalancerservice_goVelocity :vx vx :vy vy :vth vth))
  (:go-stop
   ()
   (send self :autobalancerservice_goStop))
  (:wait-foot-steps
   ()
   (send self :autobalancerservice_waitFootSteps))
  (:get-auto-balancer-param
   ()
   (send (send self :autobalancerservice_getautobalancerparam) :i_param))
  (:get-gait-generator-param
   ()
   (send (send self :autobalancerservice_getgaitgeneratorparam) :i_param))
  (:set-gait-generator-param
   (&key default-step-time default-step-height default-double-support-ratio stride-parameter)
   (let* ((current-param (send self :get-gait-generator-param))
          (param (instance hrpsys_ros_bridge::Openhrp_AutoBalancerService_GaitGeneratorParam
                           :init
                           :default_step_time (if default-step-time default-step-time (send current-param :default_step_time))
                           :default_step_height (if default-step-height default-step-height (send current-param :default_step_height))
                           :default_double_support_ratio (if default-double-support-ratio default-double-support-ratio (send current-param :default_double_support_ratio))
                           :stride_parameter (if stride-parameter stride-parameter (send current-param :stride_parameter)))))
     (send self :autobalancerservice_setgaitgeneratorparam :i_param param)))
  (:set-auto-balancer-param
   (&key default-zmp-offsets move-base-gain)
   (let* ((current-param (send self :get-auto-balancer-param))
          (param (instance hrpsys_ros_bridge::Openhrp_AutoBalancerService_AutoBalancerParam
                           :init
                           :default_zmp_offsets
                           (if default-zmp-offsets
                               (let ((dzo (copy-object (send current-param :default_zmp_offsets))))
                                 (setq (dzo . ros::_data)
                                       (apply #'concatenate float-vector (mapcar #'(lambda (x) (scale 1e-3 x))
                                                                                 default-zmp-offsets)))
                                 dzo)
                             (send current-param :default_zmp_offsets))
                           :move_base_gain (if move-base-gain move-base-gain (send current-param :move_base_gain)))))
     (send self :autobalancerservice_setautobalancerparam :i_param param)))
  (:abc-footstep->eus-footstep
   (f)
   (make-coords :pos (scale 1e3 (send f :pos))
                :rot (quaternion2matrix (send f :rot)))
   )
  (:eus-footstep->abc-footstep
   (f)
   (instance hrpsys_ros_bridge::openhrp_autobalancerservice_footstep :init
             :pos (scale 1e-3 (send f :worldpos))
             :rot (matrix2quaternion (send f :worldrot))
             :leg (format nil "~A" (if (find-method f :l/r) (send f :l/r) (send f :get :l/r))))
   )
  (:cmd-vel-cb
   (msg &key (vel-x-ratio 1.0) (vel-y-ratio 1.0) (vel-th-ratio 1.0))
   (send self :go-velocity
	 (* vel-x-ratio (send (send msg :linear) :x))
         (* vel-y-ratio (send (send msg :linear) :y))
         (* vel-th-ratio (send (send msg :angular) :z)))
   )
  (:cmd-vel-mode
   ()
   (send self :start-cmd-vel-mode)
   (do-until-key
    (send self :go-velocity 0 0 0)
    (ros::spin-once)
    (ros::sleep)
    )
   (send self :stop-cmd-vel-mode)
   )
  (:start-cmd-vel-mode
   ()
   (print ";; start cmd-vel mode")
   (ros::subscribe "cmd_vel" geometry_msgs::Twist #'send self :cmd-vel-cb)
   (send self :go-velocity 0 0 0)
   (print ";; start cmd-vel mode done.")
   )
  (:stop-cmd-vel-mode
   ()
   (print ";; stop cmd-vel mode")
   (send self :go-stop)
   (ros::unsubscribe "cmd_vel")
   (print ";; stop cmd-vel mode done.")
   )
  )

;; SoftErrorLimiterService
(defmethod rtm-ros-robot-interface
  (:set-soft-error-limit
    (name limit)
    (send self :softerrorlimiterservice_setservoerrorlimit :name name :limit limit)
    )
  )

;; StabilizerService
(defmethod rtm-ros-robot-interface
  (:set-st-param
   (&key k-tpcc-p k-tpcc-x k-brot-p k-brot-tc)
   (let ((ip (instance hrpsys_ros_bridge::openhrp_stabilizerservice_stparam
                       :init
                       :k_tpcc_x k-tpcc-x
                       :k_tpcc_p k-tpcc-p
		       :k_brot_p k-brot-p
		       :k_brot_tc k-brot-tc
                       )))
     (send self :stabilizerservice_setparameter :i_param ip)))
  (:start-st
   ()
   (send self :stabilizerservice_startstabilizer)
   )
  (:stop-st
   ()
   (send self :stabilizerservice_stopstabilizer)
   )
  )

(defun print-abc-leg-offset-conf-from-robot
  (rb)
  (let ((pav (send rb :angle-vector))
        (prc (send rb :copy-worldcoords)))
    (format t "abc_leg_offset: ")
    (let ((diff (scale (* 0.5 1e-3) (send (send (send rb :rleg :end-coords) :transformation (send rb :lleg :end-coords)) :worldpos))))
      (format t "~A,~A,~A" (elt diff 0) (elt diff 1) (elt diff 2)))
    (format t "~%")
    (send rb :angle-vector pav)
    (send rb :newcoords prc)
    ))

(defun print-end-effector-parameter-conf-from-robot
  (rb)
  (format t "end_effectors:")
  (dolist (l '(:rarm :larm :rleg :lleg))
    (let ((rl (send (send (send rb l :root-link) :parent) :joint)))
      (format t " ~A,~A,~A," l (send (send (send rb l :end-coords :parent) :joint) :name) (if rl (send rl :name) "WAIST"))
      (let* ((dif (send (send rb l :end-coords :parent) :transformation (send rb l :end-coords)))
             (wp (scale 1e-3 (send dif :worldpos))) ;; [mm] -> [m]
             (wr (normalize-vector (matrix-log (send dif :worldrot))))
             (wrn (norm (matrix-log (send dif :worldrot)))))
         (format t "~A,~A,~A," (elt wp 0) (elt wp 1) (elt wp 2))
         (format t "~A,~A,~A,~A," (elt wr 0) (elt wr 1) (elt wr 2) wrn)
         )))
  (format t "~%")
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; utility functions for seq
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  ;; dump pattern file for SequencePlayer
  ;;  rs-list : list of (list :time time0 :angle-vector av :root-coords rc ...)
  ;;  output-basename : output file (output-basename.pos, ...)
(defun dump-seq-pattern-file
  (rs-list output-basename &key (initial-sync-time 3.0)) ;; [s]
  (with-open-file
   (pf (format nil "~A.pos" output-basename) :direction :output) ;; pos file -> joint angles
   (dolist (l rs-list)
     ;; write pos file
     (format pf "~A " (+ initial-sync-time (cadr (memq :time l))))
     (let ((av (cadr (memq :angle-vector l))))
       (dotimes (i (length av))
         (format pf "~A " (deg2rad (elt av i)))
         ))
     (format pf "~%"))) ;; with-open-file for .pos file
  (when (cadr (memq :torque-vector (car rs-list)))
    (with-open-file
     (tf (format nil "~A.torque" output-basename) :direction :output) ;; torque file -> joint torques
     (dolist (l rs-list)
       ;; write torque file
       (format tf "~A " (+ initial-sync-time (cadr (memq :time l))))
       (let ((av (cadr (memq :torque-vector l))))
         (dotimes (i (length av))
           (format tf "~A " (elt av i))
           ))
       (format tf "~%")))) ;; with-open-file for .torque file
  (when (cadr (memq :root-coords (car rs-list)))
    (with-open-file
     (wf (format nil "~A.waist" output-basename) :direction :output) ;; waist file -> base position and orientation
     (dolist (l rs-list)
       ;; write waist file
       (format wf "~A " (+ initial-sync-time (cadr (memq :time l))))
       (let ((wp (scale 1e-3 (send (cadr (memq :root-coords l)) :worldpos))) ;; [mm] -> [m]
             (wr (car (send (send (cadr (memq :root-coords l)) :copy-worldcoords) :rpy-angle))))
         (format wf "~A ~A ~A " (elt wp 0) (elt wp 1) (elt wp 2))
         (format wf "~A ~A ~A " (elt wr 2) (elt wr 1) (elt wr 0))
         (format wf "~%")
         ))) ;; with-open-file for .waist file
    )
  (when (cadr (memq :zmp (car rs-list)))
    (with-open-file
     (zf (format nil "~A.zmp" output-basename) :direction :output) ;; zmp file -> root-relative zmp[m]
     (dolist (l rs-list)
       ;; write zmp file
       (format zf "~A " (+ initial-sync-time (cadr (memq :time l))))
       (let ((zp (scale 1e-3 (cadr (memq :zmp l))))) ;; [mm] -> [m]
         (format zf "~A ~A ~A " (elt zp 0) (elt zp 1) (elt zp 2))
         (format zf "~%")
         ))) ;; with-open-file for .zmp file
    )
  (when (cadr (memq :wrenches (car rs-list)))
    (with-open-file
     (wrf (format nil "~A.wrenches" output-basename) :direction :output) ;; wrench file -> force and moment ;; 6 x force-sensor-num
     (dolist (l rs-list)
       ;; write wrenches file
       (format wrf "~A " (+ initial-sync-time (cadr (memq :time l))))
       (let ((wr (cadr (memq :wrenches l))))
         (dotimes (i (length wr)) (format wrf "~A " (elt wr i))))
       (format wrf "~%")
       )) ;; with-open-file for .wrenches file
    )
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; utility functions for project generator generation
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; clone euslisp robot and objects to OpenHRP3 project file
;;   add euslisp model + locate euslisp model in OpenHRP3 world
(defun dump-project-file-by-cloning-euslisp-models
  (robot robot-file-path ;; robot euslisp model, robot VRML(or Collada) file path
   &key (object-models) (object-models-file-path) ;; list of object euslisp model, list of object VRML(or Collada) file path
        (nosim) (timestep 0.005) (dt 0.005) ;; [s]
        (output-fname (format nil "/tmp/~A" (send robot :name)))) ;; output file name "output-fname.xml"
  ;; TODO : Is longfloor.wrl necessary??
  (let ((str
         (format nil "rosrun hrpsys_ros_bridge rtmtest -t hrpsys_tools _gen_project.launch \\\
               INPUT:=~A,~A \\\
               OBJECT_MODELS:='`rospack find openhrp3`/share/OpenHRP-3.1/sample/model/longfloor.wrl,0,0,0,1,0,0,0 ~A' \\\
               OUTPUT:=~A.xml \\\
               INTEGRATE:=~A CORBA_PORT:=15005 CONF_DT_OPTION:='--dt ~A' \\\
               SIMULATION_TIMESTEP_OPTION:='--timeStep ~A' \\\
               SIMULATION_JOINT_PROPERTIES_OPTION:='--joint-properties ~A'"
                 robot-file-path
                 (gen-ProjectGenerator-model-root-coords-string robot)
                 (let ((obj-path-list
                        (mapcar #'(lambda (fpath obj) (format nil "~A,~A" fpath (gen-ProjectGenerator-model-root-coords-string obj)))
                                object-models-file-path object-models)))
                   (if obj-path-list
                       (reduce #'(lambda (x y) (format nil "~A ~A" x y)) obj-path-list)
                     ""))
                 (format nil "~A~A" output-fname (if nosim "_nosim" ""))
                 (if nosim "false" "true")
                 dt
                 timestep
                 (gen-ProjectGenerator-joint-properties-string robot)
                 )))
    (unix:system (format nil "bash -c -i \"~A;exit 0\";exit 0" str))
    ))

(defun gen-ProjectGenerator-joint-properties-string
  (robot)
  (let ((str))
    (dolist (j (send robot :joint-list))
      (if str
          (setq str (format nil "~A,~A.angle,~A" str (send j :name) (deg2rad (send j :joint-angle))))
        (setq str (format nil "~A.angle,~A" (send j :name) (deg2rad (send j :joint-angle)))))
      )
    str))

(defun gen-ProjectGenerator-model-root-coords-string
  (obj)
  (let* ((dr (matrix-log (send (car (send obj :links)) :worldrot)))
         (ndr (normalize-vector dr))
         (rpos (scale 1e-3 (send (car (send obj :links)) :worldpos))))
      (format nil "~A,~A,~A,~A,~A,~A,~A"
              (elt rpos 0) (elt rpos 1) (elt rpos 2)
              (elt ndr 0) (elt ndr 1) (elt ndr 2) (/ (elt dr 1) (elt ndr 1)) ;; openhrp3 axis angle orientation representation
              )))

