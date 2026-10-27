(vl-load-com)

(if (not (and (numberp *vp-dist*) (> *vp-dist* 0.0)))
  (setq *vp-dist* 30.0)
)

(defun VP2BS:GetScaleText (vpObj / scaleValue)
  (setq scaleValue
    (vl-catch-all-apply 'vla-get-CustomScale (list vpObj))
  )
  (if (or (vl-catch-all-error-p scaleValue)
          (not (numberp scaleValue))
          (<= scaleValue 0.0))
    nil
    (if (>= scaleValue 1.0)
      (strcat (rtos scaleValue 2 0) ":1")
      (strcat "1:" (rtos (/ 1.0 scaleValue) 2 0))
    )
  )
)

(defun VP2BS:GetScaleAttribute (blkObj / result attrs attr)
  (setq result nil)
  (if (= :vlax-true (vla-get-HasAttributes blkObj))
    (progn
      (setq attrs
        (vl-catch-all-apply 'vlax-invoke (list blkObj 'GetAttributes))
      )
      (if (not (vl-catch-all-error-p attrs))
        (foreach attr attrs
          (if (= "SCALE" (strcase (vla-get-TagString attr)))
            (setq result attr)
          )
        )
      )
    )
  )
  result
)

(defun VP2BS:GetBoundingPoints (obj distance / minVar maxVar result)
  (setq result
    (vl-catch-all-apply 'vla-GetBoundingBox (list obj 'minVar 'maxVar))
  )
  (if (vl-catch-all-error-p result)
    nil
    (list
      (mapcar '- (vlax-safearray->list minVar) (list distance distance 0.0))
      (mapcar '+ (vlax-safearray->list maxVar) (list distance distance 0.0))
    )
  )
)

(defun VP2BS:GetFirstValidViewport (ss / index ent data obj result vpNumber)
  (setq index 0 result nil)
  (while (and ss (< index (sslength ss)) (null result))
    (setq ent      (ssname ss index)
          data     (entget ent)
          vpNumber (cdr (assoc 69 data)))
    ;; DXF group 69 is the viewport ID. ID 1 is the paper-space viewport.
    (if (and (= "VIEWPORT" (cdr (assoc 0 data)))
             (numberp vpNumber)
             (> vpNumber 1))
      (progn
        (setq obj (vlax-ename->vla-object ent))
        (if (VP2BS:GetScaleText obj)
          (setq result ent)
        )
      )
    )
    (setq index (1+ index))
  )
  result
)

(defun VP2BS:WriteScale (blkEnt scaleText / blkObj scaleAttr result)
  (setq blkObj (vlax-ename->vla-object blkEnt)
        scaleAttr (VP2BS:GetScaleAttribute blkObj))
  (if (null scaleAttr)
    nil
    (progn
      (setq result
        (vl-catch-all-apply 'vla-put-TextString (list scaleAttr scaleText))
      )
      (if (vl-catch-all-error-p result)
        nil
        (progn
          (vl-catch-all-apply 'vla-Update (list scaleAttr))
          T
        )
      )
    )
  )
)

(defun VP2BS:ManualMode (/ ss index ent data vpEnt blkEnt scaleText)
  (princ "\nSelect one viewport and one attributed block: ")
  (setq ss (ssget '((0 . "VIEWPORT,INSERT"))))
  (if ss
    (progn
      (setq index 0 vpEnt nil blkEnt nil)
      (while (< index (sslength ss))
        (setq ent (ssname ss index)
              data (entget ent))
        (cond
          ((and (null vpEnt)
                (= "VIEWPORT" (cdr (assoc 0 data))))
           (setq vpEnt (VP2BS:GetFirstValidViewport (ssadd ent))))
          ((and (null blkEnt)
                (= "INSERT" (cdr (assoc 0 data)))
                (= 1 (cdr (assoc 66 data))))
           (setq blkEnt ent))
        )
        (setq index (1+ index))
      )
      (cond
        ((null vpEnt)
         (princ "\nNo valid viewport was selected."))
        ((null blkEnt)
         (princ "\nNo attributed block was selected."))
        ((null (setq scaleText
                 (VP2BS:GetScaleText (vlax-ename->vla-object vpEnt))))
         (princ "\nUnable to read the selected viewport scale."))
        ((VP2BS:WriteScale blkEnt scaleText)
         (princ (strcat "\nScale updated to " scaleText ".")))
        (T
         (princ "\nThe selected block does not contain a writable SCALE attribute."))
      )
    )
    (princ "\nNothing selected.")
  )
)

(defun VP2BS:CheckMode (/ ssBlk index blkEnt blkObj scaleAttr currentScale
                          bounds vpSS vpEnt expectedScale errorCount errSS
                          repairList answer item position)
  (setq ssBlk (ssget "_X" '((0 . "INSERT") (66 . 1)))
        errorCount 0
        errSS (ssadd)
        repairList nil)
  (if (null ssBlk)
    (princ "\nNo attributed blocks were found.")
    (progn
      (princ "\nChecking SCALE attributes...")
      (setq index 0)
      (while (< index (sslength ssBlk))
        (setq blkEnt (ssname ssBlk index)
              blkObj (vlax-ename->vla-object blkEnt)
              scaleAttr (VP2BS:GetScaleAttribute blkObj))
        (if scaleAttr
          (progn
            (setq currentScale (vla-get-TextString scaleAttr)
                  bounds (VP2BS:GetBoundingPoints blkObj *vp-dist*))
            (if bounds
              (progn
                (setq vpSS (ssget "_C" (car bounds) (cadr bounds) '((0 . "VIEWPORT")))
                      vpEnt (VP2BS:GetFirstValidViewport vpSS))
                (if vpEnt
                  (progn
                    (setq expectedScale
                      (VP2BS:GetScaleText (vlax-ename->vla-object vpEnt)))
                    (if (and expectedScale (/= currentScale expectedScale))
                      (progn
                        (setq errorCount (1+ errorCount)
                              repairList (cons (cons scaleAttr expectedScale) repairList))
                        (ssadd blkEnt errSS)
                        (setq position (cdr (assoc 10 (entget blkEnt))))
                        (princ
                          (strcat "\nMismatch at " (vl-princ-to-string position)
                                  " | Block: " currentScale
                                  " | Viewport: " expectedScale)
                        )
                      )
                    )
                  )
                )
              )
            )
          )
        )
        (setq index (1+ index))
      )
      (if (> errorCount 0)
        (progn
          (sssetfirst nil errSS)
          (princ (strcat "\nFound " (itoa errorCount) " mismatched block(s)."))
          (initget "Yes No")
          (setq answer (getkword "\nUpdate all mismatched SCALE attributes? [Yes/No] <Yes>: "))
          (if (or (null answer) (= answer "Yes"))
            (progn
              (foreach item repairList
                (vl-catch-all-apply 'vla-put-TextString (list (car item) (cdr item)))
                (vl-catch-all-apply 'vla-Update (list (car item)))
              )
              (sssetfirst nil nil)
              (princ (strcat "\nUpdated " (itoa errorCount) " block(s)."))
            )
            (princ "\nUpdate cancelled. Mismatched blocks remain selected.")
          )
        )
        (progn
          (sssetfirst nil nil)
          (princ "\nNo scale mismatches were found.")
        )
      )
    )
  )
)

(defun c:VP2BlkScale (/ *error* oldEcho doc mode newDist undoStarted)
  (setq oldEcho (getvar "CMDECHO")
        doc (vla-get-ActiveDocument (vlax-get-acad-object))
        undoStarted nil)

  (defun *error* (message)
    (if undoStarted
      (vl-catch-all-apply 'vla-EndUndoMark (list doc))
    )
    (setvar "CMDECHO" oldEcho)
    (if (and message
             (/= message "Function cancelled")
             (/= message "quit / exit abort"))
      (princ (strcat "\nError: " message))
    )
    (princ)
  )

  (setvar "CMDECHO" 0)
  (if (not (vl-catch-all-error-p
             (vl-catch-all-apply 'vla-StartUndoMark (list doc))))
    (setq undoStarted T)
  )

  (initget "Write Check Distance")
  (setq mode
    (getkword
      (strcat "\nMode [Write/Check/Distance] <Write>"
              " (distance " (rtos *vp-dist* 2 1) "): ")
    )
  )
  (if (null mode) (setq mode "Write"))

  (cond
    ((= mode "Write")
     (VP2BS:ManualMode))
    ((= mode "Check")
     (VP2BS:CheckMode))
    ((= mode "Distance")
     (initget 6)
     (setq newDist
       (getdist
         (strcat "\nViewport search distance <"
                 (rtos *vp-dist* 2 1) ">: ")
       )
     )
     (if newDist (setq *vp-dist* newDist))
     (princ (strcat "\nSearch distance: " (rtos *vp-dist* 2 1) ".")))
  )

  (if undoStarted
    (progn
      (vl-catch-all-apply 'vla-EndUndoMark (list doc))
      (setq undoStarted nil)
    )
  )
  (setvar "CMDECHO" oldEcho)
  (princ)
)

(setq c:VP2BSFIX nil)

(princ "\nVP2BlkScale FIX 2.1 SINGLE loaded. Command: VP2BlkScale.")
(princ)
