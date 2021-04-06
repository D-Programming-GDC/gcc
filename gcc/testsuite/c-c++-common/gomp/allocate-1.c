typedef enum omp_allocator_handle_t
#if __cplusplus >= 201103L
: __UINTPTR_TYPE__
#endif
{
  omp_null_allocator = 0,
  omp_default_mem_alloc = 1,
  omp_large_cap_mem_alloc = 2,
  omp_const_mem_alloc = 3,
  omp_high_bw_mem_alloc = 4,
  omp_low_lat_mem_alloc = 5,
  omp_cgroup_mem_alloc = 6,
  omp_pteam_mem_alloc = 7,
  omp_thread_mem_alloc = 8,
  __omp_allocator_handle_t_max__ = __UINTPTR_MAX__
} omp_allocator_handle_t;

int bar (int, int *, int);
omp_allocator_handle_t baz (void);

void
foo (int x, int z)
{
  int y[16] = { 0 }, r = 0, i;
  omp_allocator_handle_t h = baz ();
  #pragma omp parallel allocate (x) allocate (omp_default_mem_alloc : y) \
	      allocate ((omp_allocator_handle_t) omp_default_mem_alloc:z) firstprivate (x, y, z)
  bar (x, y, z);
  #pragma omp task private (x) firstprivate (z) allocate (omp_low_lat_mem_alloc:x,z)
  bar (0, &x, z);
  #pragma omp taskwait
  #pragma omp target teams distribute parallel for private (x) firstprivate (y) \
	      allocate ((omp_allocator_handle_t)(omp_default_mem_alloc + 0):z) \
	      allocate (omp_default_mem_alloc: x, y) allocate (omp_low_lat_mem_alloc: r) \
	      lastprivate (z) reduction(+:r)
  for (i = 0; i < 64; i++)
    {
      z = bar (0, &x, 0);
      r += bar (1, y, 0);
    }
  #pragma omp single private (x) allocate (h:x)
  ;
  #pragma omp single allocate (*&h : x) private (x)
  ;
  #pragma omp parallel shared (r, x, z)
  #pragma omp single firstprivate (r) allocate (x, r, z) private (x, z)
  ;
  #pragma omp for allocate (x) private (x)
  for (i = 0; i < 64; i++)
    x = 1;
  #pragma omp sections private (x) allocate (omp_low_lat_mem_alloc: x)
  {
    x = 1;
    #pragma omp section
    x = 2;
    #pragma omp section
    x = 3;
  }
  #pragma omp taskgroup task_reduction(+:r) allocate (omp_default_mem_alloc : r)
  #pragma omp task in_reduction(+:r) allocate (omp_default_mem_alloc : r)
  r += bar (r, &r, 0);
  #pragma omp teams private (x) firstprivate (y) allocate (h : x, y)
  bar (x, y, 0);
  #pragma omp taskloop lastprivate (x) reduction (+:r) allocate (h : x, r)
  for (i = 0; i < 16; i++)
    {
      r += bar (0, &r, 0);
      x = i;
    }
  #pragma omp taskgroup task_reduction(+:r) allocate (omp_default_mem_alloc : r)
  #pragma omp taskloop firstprivate (x) in_reduction (+:r) \
		       allocate (omp_default_mem_alloc : x, r)
  for (i = 0; i < 16; i++)
    r += bar (x, &r, 0);
  #pragma omp taskwait
}

void
qux (const omp_allocator_handle_t h)
{
  int x = 0;
  #pragma omp parallel firstprivate (x) allocate (h: x)
  x = 1;
}
