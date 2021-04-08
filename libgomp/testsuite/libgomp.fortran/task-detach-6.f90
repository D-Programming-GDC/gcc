! { dg-do run }

! { dg-additional-sources on_device_arch.c }
  ! { dg-prune-output "command-line option '-fintrinsic-modules-path=.*' is valid for Fortran but not for C" }

! Test tasks with detach clause on an offload device.  Each device
! thread spawns off a chain of tasks, that can then be executed by
! any available thread.

program task_detach_6
  use omp_lib

  integer (kind=omp_event_handle_kind) :: detach_event1, detach_event2
  integer :: x = 0, y = 0, z = 0
  integer :: thread_count

  interface
    integer function on_device_arch_nvptx() bind(C)
    end function on_device_arch_nvptx
  end interface

  !TODO See '../libgomp.c/pr99555-1.c'.
  if (on_device_arch_nvptx () /= 0) then
     error stop !TODO Until resolved, skip, with error status.
  end if

  !$omp target map (tofrom: x, y, z) map (from: thread_count)
    !$omp parallel private (detach_event1, detach_event2)
      !$omp single
	thread_count = omp_get_num_threads ()
      !$omp end single

      !$omp task detach (detach_event1) untied
	!$omp atomic update
	  x = x + 1
      !$omp end task

      !$omp task detach (detach_event2) untied
	!$omp atomic update
	  y = y + 1
	call omp_fulfill_event (detach_event1)
      !$omp end task

      !$omp task untied
	!$omp atomic update
	  z = z + 1
	call omp_fulfill_event (detach_event2)
      !$omp end task
    !$omp end parallel
  !$omp end target

  if (x /= thread_count) stop 1
  if (y /= thread_count) stop 2
  if (z /= thread_count) stop 3
end program
