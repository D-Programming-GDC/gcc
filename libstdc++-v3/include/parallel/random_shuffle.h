// -*- C++ -*-

// Copyright (C) 2007, 2008, 2009 Free Software Foundation, Inc.
//
// This file is part of the GNU ISO C++ Library.  This library is free
// software; you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software
// Foundation; either version 3, or (at your option) any later
// version.

// This library is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.

// Under Section 7 of GPL version 3, you are granted additional
// permissions described in the GCC Runtime Library Exception, version
// 3.1, as published by the Free Software Foundation.

// You should have received a copy of the GNU General Public License and
// a copy of the GCC Runtime Library Exception along with this program;
// see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see
// <http://www.gnu.org/licenses/>.

/** @file parallel/random_shuffle.h
 *  @brief Parallel implementation of std::random_shuffle().
 *  This file is a GNU parallel extension to the Standard C++ Library.
 */

// Written by Johannes Singler.

#ifndef _GLIBCXX_PARALLEL_RANDOM_SHUFFLE_H
#define _GLIBCXX_PARALLEL_RANDOM_SHUFFLE_H 1

#include <limits>
#include <bits/stl_numeric.h>
#include <parallel/parallel.h>
#include <parallel/random_number.h>

namespace __gnu_parallel
{
/** @brief Type to hold the index of a bin.
  *
  *  Since many variables of this _Self are allocated, it should be
  *  chosen as small as possible.
  */
typedef unsigned short _BinIndex;

/** @brief Data known to every thread participating in
    __gnu_parallel::__parallel_random_shuffle(). */
template<typename _RAIter>
  struct _DRandomShufflingGlobalData
  {
    typedef std::iterator_traits<_RAIter> _TraitsType;
    typedef typename _TraitsType::value_type _ValueType;
    typedef typename _TraitsType::difference_type _DifferenceType;

    /** @brief Begin iterator of the _M_source. */
    _RAIter& _M_source;

    /** @brief Temporary arrays for each thread. */
    _ValueType** _M_temporaries;

    /** @brief Two-dimensional array to hold the thread-bin distribution.
     *
     *  Dimensions (__num_threads + 1) __x (_M_num_bins + 1). */
    _DifferenceType** _M_dist;

    /** @brief Start indexes of the threads' __chunks. */
    _DifferenceType* _M_starts;

    /** @brief Number of the thread that will further process the
	corresponding bin. */
    _ThreadIndex* _M_bin_proc;

    /** @brief Number of bins to distribute to. */
    int _M_num_bins;

    /** @brief Number of bits needed to address the bins. */
    int _M_num_bits;

    /** @brief Constructor. */
    _DRandomShufflingGlobalData(_RAIter& _source)
    : _M_source(_source) { }
  };

/** @brief Local data for a thread participating in
    __gnu_parallel::__parallel_random_shuffle().
  */
template<typename _RAIter, typename RandomNumberGenerator>
  struct _DRSSorterPU
  {
    /** @brief Number of threads participating in total. */
    int __num_threads;

    /** @brief Begin __index for bins taken care of by this thread. */
    _BinIndex _M_bins_begin;

    /** @brief End __index for bins taken care of by this thread. */
    _BinIndex __bins_end;

    /** @brief Random _M_seed for this thread. */
    uint32 _M_seed;

    /** @brief Pointer to global data. */
    _DRandomShufflingGlobalData<_RAIter>* _M_sd;
  };

/** @brief Generate a random number in @__c [0,2^logp).
  *  @param logp Logarithm (basis 2) of the upper range __bound.
  *  @param __rng Random number generator to use.
  */
template<typename RandomNumberGenerator>
  inline int
  __random_number_pow2(int logp, RandomNumberGenerator& __rng)
  { return __rng.__genrand_bits(logp); }

/** @brief Random shuffle code executed by each thread.
  *  @param __pus Array of thread-local data records. */
template<typename _RAIter, typename RandomNumberGenerator>
  void 
  __parallel_random_shuffle_drs_pu(_DRSSorterPU<_RAIter,
                                 RandomNumberGenerator>* __pus)
  {
    typedef std::iterator_traits<_RAIter> _TraitsType;
    typedef typename _TraitsType::value_type _ValueType;
    typedef typename _TraitsType::difference_type _DifferenceType;

    _ThreadIndex __iam = omp_get_thread_num();
    _DRSSorterPU<_RAIter, RandomNumberGenerator>* d = &__pus[__iam];
    _DRandomShufflingGlobalData<_RAIter>* _M_sd = d->_M_sd;

    // Indexing: _M_dist[bin][processor]
    _DifferenceType __length = _M_sd->_M_starts[__iam + 1] - _M_sd->_M_starts[__iam];
    _BinIndex* __oracles = new _BinIndex[__length];
    _DifferenceType* _M_dist = new _DifferenceType[_M_sd->_M_num_bins + 1];
    _BinIndex* _M_bin_proc = new _BinIndex[_M_sd->_M_num_bins];
    _ValueType** _M_temporaries = new _ValueType*[d->__num_threads];

    // Compute oracles and count appearances.
    for (_BinIndex __b = 0; __b < _M_sd->_M_num_bins + 1; ++__b)
      _M_dist[__b] = 0;
    int _M_num_bits = _M_sd->_M_num_bits;

    _RandomNumber __rng(d->_M_seed);

    // First main loop.
    for (_DifferenceType __i = 0; __i < __length; ++__i)
      {
        _BinIndex __oracle = __random_number_pow2(_M_num_bits, __rng);
        __oracles[__i] = __oracle;

        // To allow prefix (partial) sum.
        ++(_M_dist[__oracle + 1]);
      }

    for (_BinIndex __b = 0; __b < _M_sd->_M_num_bins + 1; ++__b)
      _M_sd->_M_dist[__b][__iam + 1] = _M_dist[__b];

#   pragma omp barrier

#   pragma omp single
    {
      // Sum up bins, _M_sd->_M_dist[__s + 1][d->__num_threads] now contains the
      // total number of items in bin __s
      for (_BinIndex __s = 0; __s < _M_sd->_M_num_bins; ++__s)
        __gnu_sequential::partial_sum(_M_sd->_M_dist[__s + 1],
                                      _M_sd->_M_dist[__s + 1] + d->__num_threads + 1,
                                      _M_sd->_M_dist[__s + 1]);
    }

#   pragma omp barrier

    _SequenceIndex __offset = 0, __global_offset = 0;
    for (_BinIndex __s = 0; __s < d->_M_bins_begin; ++__s)
      __global_offset += _M_sd->_M_dist[__s + 1][d->__num_threads];

#   pragma omp barrier

    for (_BinIndex __s = d->_M_bins_begin; __s < d->__bins_end; ++__s)
      {
	for (int __t = 0; __t < d->__num_threads + 1; ++__t)
	  _M_sd->_M_dist[__s + 1][__t] += __offset;
	__offset = _M_sd->_M_dist[__s + 1][d->__num_threads];
      }

    _M_sd->_M_temporaries[__iam] = static_cast<_ValueType*>(
      ::operator new(sizeof(_ValueType) * __offset));

#   pragma omp barrier

    // Draw local copies to avoid false sharing.
    for (_BinIndex __b = 0; __b < _M_sd->_M_num_bins + 1; ++__b)
      _M_dist[__b] = _M_sd->_M_dist[__b][__iam];
    for (_BinIndex __b = 0; __b < _M_sd->_M_num_bins; ++__b)
      _M_bin_proc[__b] = _M_sd->_M_bin_proc[__b];
    for (_ThreadIndex __t = 0; __t < d->__num_threads; ++__t)
      _M_temporaries[__t] = _M_sd->_M_temporaries[__t];

    _RAIter _M_source = _M_sd->_M_source;
    _DifferenceType __start = _M_sd->_M_starts[__iam];

    // Distribute according to oracles, second main loop.
    for (_DifferenceType __i = 0; __i < __length; ++__i)
      {
        _BinIndex target_bin = __oracles[__i];
        _ThreadIndex target_p = _M_bin_proc[target_bin];

        // Last column [d->__num_threads] stays unchanged.
        ::new(&(_M_temporaries[target_p][_M_dist[target_bin + 1]++]))
	    _ValueType(*(_M_source + __i + __start));
      }

    delete[] __oracles;
    delete[] _M_dist;
    delete[] _M_bin_proc;
    delete[] _M_temporaries;

#   pragma omp barrier

    // Shuffle bins internally.
    for (_BinIndex __b = d->_M_bins_begin; __b < d->__bins_end; ++__b)
      {
        _ValueType* __begin =
                    _M_sd->_M_temporaries[__iam] +
                    ((__b == d->_M_bins_begin) ? 0 : _M_sd->_M_dist[__b][d->__num_threads]),
                  * __end =
                    _M_sd->_M_temporaries[__iam] + _M_sd->_M_dist[__b + 1][d->__num_threads];
        __sequential_random_shuffle(__begin, __end, __rng);
        std::copy(__begin, __end, _M_sd->_M_source + __global_offset +
            ((__b == d->_M_bins_begin) ? 0 : _M_sd->_M_dist[__b][d->__num_threads]));
      }

    ::operator delete(_M_sd->_M_temporaries[__iam]);
  }

/** @brief Round up to the next greater power of 2.
  *  @param __x _Integer to round up */
template<typename _Tp>
  _Tp 
  __round_up_to_pow2(_Tp __x)
  {
    if (__x <= 1)
      return 1;
    else
      return (_Tp)1 << (__log2(__x - 1) + 1);
  }

/** @brief Main parallel random shuffle step.
  *  @param __begin Begin iterator of sequence.
  *  @param __end End iterator of sequence.
  *  @param __n Length of sequence.
  *  @param __num_threads Number of threads to use.
  *  @param __rng Random number generator to use.
  */
template<typename _RAIter, typename RandomNumberGenerator>
  void
  __parallel_random_shuffle_drs(_RAIter __begin,
			      _RAIter __end,
			      typename std::iterator_traits
			      <_RAIter>::difference_type __n,
			      _ThreadIndex __num_threads,
			      RandomNumberGenerator& __rng)
  {
    typedef std::iterator_traits<_RAIter> _TraitsType;
    typedef typename _TraitsType::value_type _ValueType;
    typedef typename _TraitsType::difference_type _DifferenceType;

    _GLIBCXX_CALL(__n)

    const _Settings& __s = _Settings::get();

    if (__num_threads > __n)
      __num_threads = static_cast<_ThreadIndex>(__n);

    _BinIndex _M_num_bins, __num_bins_cache;

#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_L1
    // Try the L1 cache first.

    // Must fit into L1.
    __num_bins_cache = std::max<_DifferenceType>(
        1, __n / (__s.L1_cache_size_lb / sizeof(_ValueType)));
    __num_bins_cache = __round_up_to_pow2(__num_bins_cache);

    // No more buckets than TLB entries, power of 2
    // Power of 2 and at least one element per bin, at most the TLB size.
    _M_num_bins = std::min<_DifferenceType>(__n, __num_bins_cache);

#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_TLB
    // 2 TLB entries needed per bin.
    _M_num_bins = std::min<_DifferenceType>(__s.TLB_size / 2, _M_num_bins);
#endif
    _M_num_bins = __round_up_to_pow2(_M_num_bins);

    if (_M_num_bins < __num_bins_cache)
      {
#endif
        // Now try the L2 cache
        // Must fit into L2
        __num_bins_cache = static_cast<_BinIndex>(std::max<_DifferenceType>(
            1, __n / (__s.L2_cache_size / sizeof(_ValueType))));
        __num_bins_cache = __round_up_to_pow2(__num_bins_cache);

        // No more buckets than TLB entries, power of 2.
        _M_num_bins = static_cast<_BinIndex>(
            std::min(__n, static_cast<_DifferenceType>(__num_bins_cache)));
        // Power of 2 and at least one element per bin, at most the TLB size.
#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_TLB
        // 2 TLB entries needed per bin.
        _M_num_bins = std::min(
            static_cast<_DifferenceType>(__s.TLB_size / 2), _M_num_bins);
#endif
          _M_num_bins = __round_up_to_pow2(_M_num_bins);
#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_L1
      }
#endif

    __num_threads = std::min<_BinIndex>(__num_threads, _M_num_bins);

    if (__num_threads <= 1)
      return __sequential_random_shuffle(__begin, __end, __rng);

    _DRandomShufflingGlobalData<_RAIter> _M_sd(__begin);
    _DRSSorterPU<_RAIter, _RandomNumber >* __pus;
    _DifferenceType* _M_starts;

#   pragma omp parallel num_threads(__num_threads)
      {
        _ThreadIndex __num_threads = omp_get_num_threads();
#       pragma omp single
          {
            __pus = new _DRSSorterPU<_RAIter, _RandomNumber>
                [__num_threads];

            _M_sd._M_temporaries = new _ValueType*[__num_threads];
            _M_sd._M_dist = new _DifferenceType*[_M_num_bins + 1];
            _M_sd._M_bin_proc = new _ThreadIndex[_M_num_bins];
            for (_BinIndex __b = 0; __b < _M_num_bins + 1; ++__b)
              _M_sd._M_dist[__b] = new _DifferenceType[__num_threads + 1];
            for (_BinIndex __b = 0; __b < (_M_num_bins + 1); ++__b)
              {
                _M_sd._M_dist[0][0] = 0;
                _M_sd._M_dist[__b][0] = 0;
              }
            _M_starts = _M_sd._M_starts = new _DifferenceType[__num_threads + 1];
            int bin_cursor = 0;
            _M_sd._M_num_bins = _M_num_bins;
            _M_sd._M_num_bits = __log2(_M_num_bins);

            _DifferenceType __chunk_length = __n / __num_threads,
                            __split = __n % __num_threads, __start = 0;
            _DifferenceType bin_chunk_length = _M_num_bins / __num_threads,
                            bin_split = _M_num_bins % __num_threads;
            for (_ThreadIndex __i = 0; __i < __num_threads; ++__i)
              {
                _M_starts[__i] = __start;
                __start += (__i < __split) ? (__chunk_length + 1) : __chunk_length;
                int __j = __pus[__i]._M_bins_begin = bin_cursor;

                // Range of bins for this processor.
                bin_cursor += (__i < bin_split) ?
                    (bin_chunk_length + 1) : bin_chunk_length;
                __pus[__i].__bins_end = bin_cursor;
                for (; __j < bin_cursor; ++__j)
                  _M_sd._M_bin_proc[__j] = __i;
                __pus[__i].__num_threads = __num_threads;
                __pus[__i]._M_seed = __rng(std::numeric_limits<uint32>::max());
                __pus[__i]._M_sd = &_M_sd;
              }
            _M_starts[__num_threads] = __start;
          } //single
        // Now shuffle in parallel.
        __parallel_random_shuffle_drs_pu(__pus);
      }  // parallel

    delete[] _M_starts;
    delete[] _M_sd._M_bin_proc;
    for (int __s = 0; __s < (_M_num_bins + 1); ++__s)
      delete[] _M_sd._M_dist[__s];
    delete[] _M_sd._M_dist;
    delete[] _M_sd._M_temporaries;

    delete[] __pus;
  }

/** @brief Sequential __cache-efficient random shuffle.
 *  @param __begin Begin iterator of sequence.
 *  @param __end End iterator of sequence.
 *  @param __rng Random number generator to use.
 */
template<typename _RAIter, typename RandomNumberGenerator>
  void
  __sequential_random_shuffle(_RAIter __begin, 
                            _RAIter __end,
                            RandomNumberGenerator& __rng)
  {
    typedef std::iterator_traits<_RAIter> _TraitsType;
    typedef typename _TraitsType::value_type _ValueType;
    typedef typename _TraitsType::difference_type _DifferenceType;

    _DifferenceType __n = __end - __begin;
    const _Settings& __s = _Settings::get();

    _BinIndex _M_num_bins, __num_bins_cache;

#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_L1
    // Try the L1 cache first, must fit into L1.
    __num_bins_cache =
        std::max<_DifferenceType>
            (1, __n / (__s.L1_cache_size_lb / sizeof(_ValueType)));
    __num_bins_cache = __round_up_to_pow2(__num_bins_cache);

    // No more buckets than TLB entries, power of 2
    // Power of 2 and at least one element per bin, at most the TLB size
    _M_num_bins = std::min(__n, (_DifferenceType)__num_bins_cache);
#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_TLB
    // 2 TLB entries needed per bin
    _M_num_bins = std::min((_DifferenceType)__s.TLB_size / 2, _M_num_bins);
#endif
    _M_num_bins = __round_up_to_pow2(_M_num_bins);

    if (_M_num_bins < __num_bins_cache)
      {
#endif
        // Now try the L2 cache, must fit into L2.
        __num_bins_cache =
            static_cast<_BinIndex>(std::max<_DifferenceType>(
                1, __n / (__s.L2_cache_size / sizeof(_ValueType))));
        __num_bins_cache = __round_up_to_pow2(__num_bins_cache);

        // No more buckets than TLB entries, power of 2
        // Power of 2 and at least one element per bin, at most the TLB size.
        _M_num_bins = static_cast<_BinIndex>
            (std::min(__n, static_cast<_DifferenceType>(__num_bins_cache)));

#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_TLB
        // 2 TLB entries needed per bin
        _M_num_bins =
            std::min<_DifferenceType>(__s.TLB_size / 2, _M_num_bins);
#endif
        _M_num_bins = __round_up_to_pow2(_M_num_bins);
#if _GLIBCXX_RANDOM_SHUFFLE_CONSIDER_L1
      }
#endif

    int _M_num_bits = __log2(_M_num_bins);

    if (_M_num_bins > 1)
      {
        _ValueType* __target = static_cast<_ValueType*>(
          ::operator new(sizeof(_ValueType) * __n));
        _BinIndex* __oracles = new _BinIndex[__n];
        _DifferenceType* __dist0 = new _DifferenceType[_M_num_bins + 1],
                       * __dist1 = new _DifferenceType[_M_num_bins + 1];

        for (int __b = 0; __b < _M_num_bins + 1; ++__b)
          __dist0[__b] = 0;

        _RandomNumber bitrng(__rng(0xFFFFFFFF));

        for (_DifferenceType __i = 0; __i < __n; ++__i)
          {
            _BinIndex __oracle = __random_number_pow2(_M_num_bits, bitrng);
            __oracles[__i] = __oracle;

            // To allow prefix (partial) sum.
            ++(__dist0[__oracle + 1]);
          }

        // Sum up bins.
        __gnu_sequential::partial_sum(__dist0, __dist0 + _M_num_bins + 1, __dist0);

        for (int __b = 0; __b < _M_num_bins + 1; ++__b)
          __dist1[__b] = __dist0[__b];

        // Distribute according to oracles.
        for (_DifferenceType __i = 0; __i < __n; ++__i)
          ::new(&(__target[(__dist0[__oracles[__i]])++])) _ValueType(*(__begin + __i));

        for (int __b = 0; __b < _M_num_bins; ++__b)
          {
            __sequential_random_shuffle(__target + __dist1[__b],
                                      __target + __dist1[__b + 1],
                                      __rng);
          }

        // Copy elements back.
        std::copy(__target, __target + __n, __begin);

        delete[] __dist0;
        delete[] __dist1;
        delete[] __oracles;
        ::operator delete(__target);
      }
    else
      __gnu_sequential::random_shuffle(__begin, __end, __rng);
  }

/** @brief Parallel random public call.
 *  @param __begin Begin iterator of sequence.
 *  @param __end End iterator of sequence.
 *  @param __rng Random number generator to use.
 */
template<typename _RAIter, typename RandomNumberGenerator>
  inline void
  __parallel_random_shuffle(_RAIter __begin,
                          _RAIter __end,
                          RandomNumberGenerator __rng = _RandomNumber())
  {
    typedef std::iterator_traits<_RAIter> _TraitsType;
    typedef typename _TraitsType::difference_type _DifferenceType;
    _DifferenceType __n = __end - __begin;
    __parallel_random_shuffle_drs(__begin, __end, __n, __get_max_threads(), __rng) ;
  }

}

#endif /* _GLIBCXX_PARALLEL_RANDOM_SHUFFLE_H */
