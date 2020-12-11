/* Output D language descriptions of types.
   Copyright (C) 2019 Free Software Foundation, Inc.

This file is part of GCC.

GCC is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation; either version 3, or (at your option) any later
version.

GCC is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
for more details.

You should have received a copy of the GNU General Public License
along with GCC; see the file COPYING3.  If not see
<http://www.gnu.org/licenses/>.  */

/* This file is used during the build process to emit D language
   descriptions of declarations from C header files.  It uses the
   debug info hooks to emit the descriptions.  The D language
   descriptions then become part of the D runtime support library.  */

#include "config.h"
#include "system.h"
#include "coretypes.h"
#include "tm.h"
#include "tree.h"
#include "diagnostic-core.h"
#include "debug.h"
#include "stor-layout.h"
#include "fold-const.h"

namespace {

/* We dump this information from the debug hooks.  This gives us a
   stable and maintainable API to hook into.  In order to work
   correctly when -g is used, we build our own hooks structure which
   wraps the hooks we need to change.  */

/* Our debug hooks.  This is initialized by dump_d_spec_init.  */

struct gcc_debug_hooks d_debug_hooks;

/* The real debug hooks.  */

const struct gcc_debug_hooks *real_debug_hooks;

/* The file where we should write information.  */

FILE *d_dump_file;

/* A queue of decls to output.  */

static GTY(()) vec<tree, va_gc> *queue;

/* A hash table of macros we have seen.  */

htab_t macro_hash;

/* The type of a value in macro_hash.  */

struct macro_hash_value
{
  /* The name stored in the hash table.  */
  char *name;
  /* The value of the macro.  */
  char *value;
};

/* A container for the data we pass around when generating information
   at the end of the compilation.  */

struct ddump_container
{
  /* DECLs that we have already seen.  */
  hash_set<tree> decls_seen;

  /* Types which may potentially have to be defined as dummy
     types.  */
  hash_set<const char *> pot_dummy_types;

  /* D keywords.  */
  htab_t keyword_hash;

  /* Global type definitions.  */
  htab_t type_hash;

  /* Invalid types.  */
  htab_t invalid_hash;

  /* Obstack used to write out a type definition.  */
  struct obstack type_obstack;
};

/* Calculate the hash value for an entry in the macro hash table.  */

hashval_t
macro_hash_hashval (const void *val)
{
  const struct macro_hash_value *mhval = (const struct macro_hash_value *) val;
  return htab_hash_string (mhval->name);
}

/* Compare values in the macro hash table for equality.  */

int
macro_hash_eq (const void *v1, const void *v2)
{
  const struct macro_hash_value *mhv1 = (const struct macro_hash_value *) v1;
  const struct macro_hash_value *mhv2 = (const struct macro_hash_value *) v2;
  return strcmp (mhv1->name, mhv2->name) == 0;
}

/* Free values deleted from the macro hash table.  */

void
macro_hash_del (void *v)
{
  struct macro_hash_value *mhv = (struct macro_hash_value *) v;
  XDELETEVEC (mhv->name);
  XDELETEVEC (mhv->value);
  XDELETE (mhv);
}

/* For the string hash tables.  */

int
string_hash_eq (const void *y1, const void *y2)
{
  return strcmp ((const char *) y1, (const char *) y2) == 0;
}

} // namespace

namespace d_dump_spec {

/* Specific flags for individual FORMAT_INFO bit values.  */

enum dfi_mask
{
  /* If we can simply use a type name without needing to define it.  */
  DFI_TYPE_NAME  = 1 << 0,
  /* If we can output a function type.  */
  DFI_FUNCTION   = 1 << 1,
  /* If we can output reference types.  */
  DFI_REFERENCE  = 1 << 2,
  /* If we can output const qualifiers.  */
  DFI_CONST_QUAL = 1 << 3,
  /* If the type is an anonymous record or enum field.  */
  DFI_ANON_FIELD = 1 << 4
};

/* Format information flags we pass around.  */

struct format_info
{
  unsigned flags;
  const char *anon_type_name;

  /* Constructor.  */
  explicit format_info (unsigned flags_)
  : flags (flags_), anon_type_name (NULL)
  { }

  explicit format_info (unsigned flags_, const char *anon_type_name_)
  : flags (flags_), anon_type_name (anon_type_name_)
  { }

  inline bool
  use_type_name (void)
  {
    return (flags & DFI_TYPE_NAME) != 0;
  }

  inline bool
  is_func_ok (void)
  {
    return (flags & DFI_FUNCTION) != 0;
  }

  inline bool
  is_ref_ok (void)
  {
    return (flags & DFI_REFERENCE) != 0;
  }

  inline bool
  is_const_ok (void)
  {
    return (flags & DFI_CONST_QUAL) != 0;
  }

  inline bool
  is_anon_field_type (void)
  {
    return (flags & DFI_ANON_FIELD) != 0;
  }
};

/* Prototypes for forward referenced functions */

static bool format_type (struct ddump_container &, tree, format_info &);

/* A macro definition.  */

static void
define (unsigned int lineno, const char *buffer)
{
  const char *p;

  real_debug_hooks->define (lineno, buffer);

  /* Skip macro functions.  */
  for (p = buffer; *p != '\0' && *p != ' '; ++p)
    {
      if (*p == '(')
	return;
    }

  if (*p == '\0')
    return;

  const char *name_end = p;
  ++p;

  if (*p == '\0')
    return;

  char *copy = XNEWVEC (char, name_end - buffer + 1);
  memcpy (copy, buffer, name_end - buffer);
  copy[name_end - buffer] = '\0';

  struct macro_hash_value *mhval = XNEW (struct macro_hash_value);
  mhval->name = copy;
  mhval->value = NULL;

  hashval_t hashval = htab_hash_string (copy);
  void **slot = htab_find_slot_with_hash (macro_hash, mhval, hashval,
					  NO_INSERT);

  /* For simplicity, we force all names to be hidden by adding an
     initial underscore, and let the user undo this as needed.  */
  size_t out_len = strlen (p) * 2 + 1;
  char *out_buffer = XNEWVEC (char, out_len);
  char *q = out_buffer;
  bool saw_operand = false;
  bool need_operand = false;
  bool saw_long_suffix = false;

  while (*p != '\0')
    {
      switch (*p)
	{
	case 'A': case 'B': case 'C': case 'D': case 'E': case 'F':
	case 'G': case 'H': case 'I': case 'J': case 'K': case 'L':
	case 'M': case 'N': case 'O': case 'P': case 'Q': case 'R':
	case 'S': case 'T': case 'U': case 'V': case 'W': case 'X':
	case 'Y': case 'Z':
	case 'a': case 'b': case 'c': case 'd': case 'e': case 'f':
	case 'g': case 'h': case 'i': case 'j': case 'k': case 'l':
	case 'm': case 'n': case 'o': case 'p': case 'q': case 'r':
	case 's': case 't': case 'u': case 'v': case 'w': case 'x':
	case 'y': case 'z':
	case '_':
	  {
	    /* The start of an identifier.  Technically we should also
	       worry about UTF-8 identifiers, but they are not a
	       problem for practical uses of -fdump-d-spec so we
	       don't worry about them.  */
	    if (saw_operand)
	      goto Lunknown;

	    const char *start = p;
	    while (ISALNUM (*p) || *p == '_')
	      ++p;

	    char *n = XALLOCAVEC (char, p - start + 1);
	    memcpy (n, start, p - start);
	    n[p - start] = '\0';

	    struct macro_hash_value idval;
	    idval.name = n;
	    idval.value = NULL;
	    if (htab_find (macro_hash, &idval) == NULL)
	      {
		/* This is a reference to a name which was not defined
		   as a macro.  */
		goto Lunknown;
	      }

	    memcpy (q, start, p - start);
	    q += p - start;
	    saw_operand = true;
	    need_operand = false;
	  }
	  break;

	case '.':
	  if (!ISDIGIT (p[1]))
	    goto Lunknown;

	  gcc_fallthrough ();

	case '0': case '1': case '2': case '3': case '4':
	case '5': case '6': case '7': case '8': case '9':
	  {
	    const char *start = p;
	    int base = 10;

	    /* Handle base-switching prefixes for hex and octal.  */
	    if (*p == '0')
	      {
		switch (p[1])
		  {
		  case 'x':
		  case 'X':
		    p += 2;
		    base = 16;
		    break;

		  case '0': case '1': case '2': case '3':
		  case '4': case '5': case '6': case '7':
		    base = 8;
		    break;
		  }
	      }

	    if (base != 8)
	      {
		while (ISDIGIT (*p) || *p == '.' || *p == 'e' || *p == 'E'
		       || (base == 16 && ((*p >= 'a' && *p <= 'f')
					  || (*p >= 'A' && *p <= 'F'))))
		  ++p;

		memcpy (q, start, p - start);
		q += p - start;
	      }
	    else
	      {
		char buf[100];
		HOST_WIDE_INT num = 0;

		while (ISDIGIT (*p))
		  {
		    int i = *p - '0';

		    if (i >= base)
		      goto Lunknown;

		    num *= base;
		    num += i;
		    ++p;
		  }

		int buf_len = snprintf (buf, sizeof (buf),
					HOST_WIDE_INT_PRINT_HEX, num);
		memcpy (q, buf, buf_len);
		q += buf_len;
	      }
	    while (*p == 'u' || *p == 'U' || *p == 'l' || *p == 'L'
		   || *p == 'f' || *p == 'F'
		   || *p == 'd' || *p == 'D')
	      {
		/* D doesn't have decimal floats.  */
		if (*p == 'd' || *p == 'D')
		  goto Lunknown;

		/* D doesn't recognize 'l' or 'LL' suffixes, so rewrite to
		   ensure there's only ever one 'L'.  */
		if (*p == 'l' || *p == 'L')
		  {
		    if (!saw_long_suffix)
		      *q++ = 'L';

		    saw_long_suffix = 1;
		    ++p;
		  }
		else
		  *q++ = *p++;
	      }

	    /* We'll pick up the exponent, if any, as an
	       expression.  */
	    saw_operand = true;
	    need_operand = false;
	  }
	  break;

	case ' ': case '\t':
	  *q++ = *p++;
	  break;

	case '(':
	  /* Always OK, not part of an operand, presumed to start an
	     operand.  */
	  *q++ = *p++;
	  saw_operand = false;
	  need_operand = false;
	  break;

	case ')':
	  /* OK if we don't need an operand, and presumed to indicate
	     an operand.  */
	  if (need_operand)
	    goto Lunknown;

	  *q++ = *p++;
	  saw_operand = true;
	  break;

	case '+': case '-':
	  /* Always OK, but not part of an operand.  */
	  *q++ = *p++;
	  saw_operand = false;
	  break;

	case '*': case '/': case '%': case '|': case '&': case '^':
	  /* Must be a binary operator.  */
	  if (!saw_operand)
	    goto Lunknown;

	  *q++ = *p++;
	  saw_operand = false;
	  need_operand = true;
	  break;

	case '=':
	  *q++ = *p++;

	  if (*p != '=')
	    goto Lunknown;

	  /* Must be a binary operator.  */
	  if (!saw_operand)
	    goto Lunknown;

	  *q++ = *p++;
	  saw_operand = false;
	  need_operand = true;
	  break;

	case '!':
	  *q++ = *p++;

	  if (*p == '=')
	    {
	      /* Must be a binary operator.  */
	      if (!saw_operand)
		goto Lunknown;

	      *q++ = *p++;
	      saw_operand = false;
	      need_operand = true;
	    }
	  else
	    {
	      /* Must be a unary operator.  */
	      if (saw_operand)
		goto Lunknown;

	      need_operand = true;
	    }
	  break;

	case '<': case '>':
	  /* Must be a binary operand, may be << or >> or <= or >=.  */
	  if (!saw_operand)
	    goto Lunknown;

	  *q++ = *p++;

	  if (*p == *(p - 1) || *p == '=')
	    *q++ = *p++;

	  saw_operand = false;
	  need_operand = true;
	  break;

	case '~':
	  /* Must be a unary operand.  */
	  if (saw_operand)
	    goto Lunknown;

	  *q++ = *p++;
	  need_operand = true;
	  break;

	case '"':
	case '\'':
	  {
	    if (saw_operand)
	      goto Lunknown;

	    char quote = *p;
	    *q++ = *p++;
	    int count = 0;

	    while (*p != quote)
	      {
		if (*p == '\0')
		  goto Lunknown;

		++count;

		if (*p != '\\')
		  {
		    *q++ = *p++;
		    continue;
		  }

		*q++ = *p++;
		switch (*p)
		  {
		  case '0': case '1': case '2': case '3':
		  case '4': case '5': case '6': case '7':
		    {
		      int c = 0;

		      while (*p >= '0' && *p <= '7')
			{
			  *q++ = *p++;
			  ++c;
			}

		      /* D octal characters are always 3 digits.  */
		      if (c != 3)
			goto Lunknown;
		    }
		    break;

		  case 'x':
		    {
		      int c = 0;
		      *q++ = *p++;

		      while (ISXDIGIT (*p))
			{
			  *q++ = *p++;
			  ++c;
			}

		      /* D hex characters are always 2 digits.  */
		      if (c != 2)
			goto Lunknown;
		    }
		    break;

		  case 'a': case 'b': case 'f': case 'n': case 'r':
		  case 't': case 'v': case '\\': case '\'': case '"':
		    *q++ = *p++;
		    break;

		  default:
		    goto Lunknown;
		  }
	      }

	    *q++ = *p++;

	    if (quote == '\'' && count != 1)
	      goto Lunknown;

	    saw_operand = true;
	    need_operand = false;
	    break;
	  }

	default:
	  goto Lunknown;
	}
    }

  if (need_operand)
    goto Lunknown;

  gcc_assert ((size_t) (q - out_buffer) < out_len);
  *q = '\0';

  mhval->value = out_buffer;

  if (slot == NULL)
    {
      slot = htab_find_slot_with_hash (macro_hash, mhval, hashval, INSERT);
      gcc_assert (slot != NULL && *slot == NULL);
    }
  else
    {
      if (*slot != NULL)
	macro_hash_del (*slot);
    }

  *slot = mhval;
  return;

Lunknown:
  fprintf (d_dump_file, "// unknown define %s\n", buffer);

  if (slot != NULL)
    htab_clear_slot (macro_hash, slot);

  XDELETEVEC (out_buffer);
  XDELETEVEC (copy);
}

/* A macro undef.  */

static void
undef (unsigned int lineno, const char *buffer)
{
  real_debug_hooks->undef (lineno, buffer);

  struct macro_hash_value mhval;
  mhval.name = CONST_CAST (char *, buffer);
  mhval.value = NULL;

  void **slot = htab_find_slot (macro_hash, &mhval, NO_INSERT);
  if (slot != NULL)
    htab_clear_slot (macro_hash, slot);
}

/* Add a function or variable DECL to the QUEUE vector.  */

static void
enqueue_decl (tree decl)
{
  if (!TREE_PUBLIC (decl)
      || DECL_IS_UNDECLARED_BUILTIN (decl)
      || DECL_NAME (decl) == NULL_TREE)
    return;

  vec_safe_push (queue, decl);
}

/* A function decl.  */

static void
function_decl (tree decl)
{
  real_debug_hooks->function_decl (decl);
  enqueue_decl (decl);
}

/* A global variable decl.  */

static void
early_global_decl (tree decl)
{
  enqueue_decl (decl);
  if (TREE_CODE (decl) != FUNCTION_DECL || DECL_STRUCT_FUNCTION (decl) != NULL)
    real_debug_hooks->early_global_decl (decl);
}

static void
late_global_decl (tree decl)
{
  real_debug_hooks->late_global_decl (decl);
}

/* A type declaration.  */

static void
type_decl (tree decl, int local)
{
  real_debug_hooks->type_decl (decl, local);

  if (local || DECL_IS_UNDECLARED_BUILTIN (decl))
    return;

  if (DECL_NAME (decl) == NULL_TREE
      && (TYPE_NAME (TREE_TYPE (decl)) == NULL_TREE
	  || TREE_CODE (TYPE_NAME (TREE_TYPE (decl))) != IDENTIFIER_NODE)
      && TREE_CODE (TREE_TYPE (decl)) != ENUMERAL_TYPE)
    return;

  vec_safe_push (queue, decl);
}

/* Append an IDENTIFIER_NODE to OB.  */

static void
append_string (struct obstack *ob, tree id)
{
  obstack_grow (ob, IDENTIFIER_POINTER (id), IDENTIFIER_LENGTH (id));
}

/* Append an artificial variable name with the suffix _INDEX to OB.
   Returns INDEX + 1.  */

static unsigned int
append_artificial_bitfield (struct obstack *ob, unsigned int index)
{
  char buf[100];

  /* Identifier may not be unique.  */
  obstack_grow (ob, "__bitfield_padding", 18);
  snprintf (buf, sizeof buf, "_%u", index);
  obstack_grow (ob, buf, strlen (buf));

  return index + 1;
}

/* Append the variable name from DECL to OB.  If the name is in the
   KEYWORD_HASH, prepend an '_'.  */

static void
append_decl_name (struct obstack *ob, tree decl, htab_t keyword_hash)
{
  append_string (ob, DECL_NAME (decl));
  /* Add underscore after variable name if a keyword.  */
  const char *var_name = IDENTIFIER_POINTER (DECL_NAME (decl));
  if (htab_find_slot (keyword_hash, var_name, NO_INSERT) != NULL)
    obstack_1grow (ob, '_');
}

/* Returns true if TYPE corresponds to a D tagged type.  */

static bool
is_tagged_type (const_tree type)
{
  enum tree_code code = TREE_CODE (type);

  return TYPE_IDENTIFIER (type)
    && (code == RECORD_TYPE || code == UNION_TYPE
	|| code == QUAL_UNION_TYPE || code == ENUMERAL_TYPE);
}

/* Write the D version of integer TYPE to TYPE_OBSTACK.  Return true if the type
   can be represented in D, false otherwise.  */

static bool
format_integer_type (struct obstack *type_obstack, tree type)
{
  bool ret = true;
  const char *s;
  char buf[100];

  switch (int_size_in_bytes (type))
    {
    case 1:
      s = TREE_CODE (type) == INTEGER_TYPE && TYPE_STRING_FLAG (type) ? "char"
	: TYPE_UNSIGNED (type) ? "ubyte" : "byte";
      break;

    case 2:
      s = TREE_CODE (type) == INTEGER_TYPE && TYPE_STRING_FLAG (type) ? "wchar"
	: TYPE_UNSIGNED (type) ? "ushort" : "short";
      break;

    case 4:
      s = TREE_CODE (type) == INTEGER_TYPE && TYPE_STRING_FLAG (type) ? "dchar"
	: TYPE_UNSIGNED (type) ? "uint" : "int";
      break;

    case 8:
      s = TYPE_UNSIGNED (type) ? "ulong" : "long";
      break;

    default:
      snprintf (buf, sizeof (buf), "INVALID-int-%u%s",
		TYPE_PRECISION (type),
		TYPE_UNSIGNED (type) ? "u" : "");
      s = buf;
      ret = false;
      break;
    }

  obstack_grow (type_obstack, s, strlen (s));
  return ret;
}

/* Write the D version of real TYPE to TYPE_OBSTACK.  Return true if the type
   can be represented in D, false otherwise.  */

static bool
format_real_type (struct obstack *type_obstack, tree type)
{
  bool ret = true;
  const char *s;
  char buf[100];

  switch (TYPE_PRECISION (type))
    {
    case 32:
      s = "float";
      break;

    case 64:
      s = "double";
      break;

    default:
      if (TYPE_PRECISION (type) == LONG_DOUBLE_TYPE_SIZE)
	s = "real";
      else
	{
	  snprintf (buf, sizeof (buf), "INVALID-float-%u",
		    TYPE_PRECISION (type));
	  s = buf;
	  ret = false;
	}
      break;
    }

  obstack_grow (type_obstack, s, strlen (s));
  return ret;
}

/* Write the D version of complex TYPE to TYPE_OBSTACK.  Return true if the type
   can be represented in D, false otherwise.  */

static bool
format_complex_type (struct obstack *type_obstack, tree type)
{
  bool ret = true;
  const char *s;
  char buf[100];
  tree real_type = TREE_TYPE (type);

  if (TREE_CODE (real_type) == REAL_TYPE)
    {
      switch (TYPE_PRECISION (real_type))
	{
	case 32:
	  s = "cfloat";
	  break;

	case 64:
	  s = "cdouble";
	  break;

	default:
	  if (TYPE_PRECISION (real_type) == LONG_DOUBLE_TYPE_SIZE)
	    s = "creal";
	  else
	    {
	      snprintf (buf, sizeof (buf), "INVALID-complex-%u",
			2 * TYPE_PRECISION (real_type));
	      s = buf;
	      ret = false;
	    }
	  break;
	}
    }
  else
    {
      s = "INVALID-complex-non-real";
      ret = false;
    }

  obstack_grow (type_obstack, s, strlen (s));
  return ret;
}

/* Write the D version of pointer TYPE to CONTAINER.TYPE_OBSTACK using INFO to
   control how the type is formatted.  Return true if the type can be
   represented in D, false otherwise.  */

static bool
format_pointer_type (struct ddump_container &container, tree type,
		     format_info &info)
{
  tree basetype = TREE_TYPE (type);
  bool is_pointer_const = TYPE_READONLY (type);
  bool is_base_const = TYPE_READONLY (basetype);
  struct obstack *ob = &container.type_obstack;
  bool ret = true;
  format_info basetype_info (info.flags & DFI_ANON_FIELD, info.anon_type_name);

  /* Don't force the TYPE_NAME if base type is anonymous.  */
  if (!info.is_anon_field_type ())
    basetype_info.flags |= DFI_TYPE_NAME;

  /* Allow FUNCTION_TYPE types to be emitted.  */
  if (TREE_CODE (basetype) == FUNCTION_TYPE)
    basetype_info.flags |= DFI_FUNCTION;

  /* Emit const qualifier if haven't already done so.  */
  if (info.is_const_ok ())
    {
      if (is_pointer_const)
	obstack_grow (ob, "const ", 6);
      else if (is_base_const)
	obstack_grow (ob, "const(", 6);
      else
	basetype_info.flags |= DFI_CONST_QUAL;
    }

  if (!format_type (container, basetype, basetype_info))
    ret = false;

  if (info.is_const_ok () && !is_pointer_const && is_base_const)
    obstack_1grow (ob, ')');

  if (!basetype_info.is_func_ok ())
    obstack_1grow (ob, '*');

  /* The pointer here can be used without the struct or union
     definition.  So this struct or union is a potential dummy
     type.  */
  if (is_tagged_type (basetype))
    {
      const char *ident = IDENTIFIER_POINTER (TYPE_IDENTIFIER (basetype));
      container.pot_dummy_types.add (ident);
    }

  return ret;
}

/* Write the D version of reference TYPE to CONTAINER.TYPE_OBSTACK using INFO
   to control how the type is formatted.  Return true if the type can be
   represented in D, false otherwise.  */

static bool
format_reference_type (struct ddump_container &container, tree type,
		       format_info &info)
{
  struct obstack *ob = &container.type_obstack;
  bool ret = true;

  /* The ref keyword is only valid in the context of function return or
     parameter types.  */
  if (!info.is_ref_ok ())
    ret = false;

  obstack_grow (ob, "ref ", 4);

  /* Strip 'ref' from the info context.  */
  unsigned basetype_info_mask = (DFI_TYPE_NAME | (info.flags & DFI_CONST_QUAL));
  format_info basetype_info (basetype_info_mask);

  if (!format_type (container, TREE_TYPE (type), basetype_info))
    ret = false;

  return ret;
}

/* Write the D version of array TYPE to CONTAINER.TYPE_OBSTACK using INFO to
   control how the type is formatted.  Return true if the type can be
   represented in D, false otherwise.  */

static bool
format_array_type (struct ddump_container &container, tree type,
		   format_info &info)
{
  struct obstack *ob = &container.type_obstack;
  bool ret = true;
  format_info basetype_info (info.flags & (DFI_CONST_QUAL | DFI_ANON_FIELD),
			     info.anon_type_name);

  /* Don't force the TYPE_NAME if base type is anonymous.  */
  if (!info.is_anon_field_type ())
    basetype_info.flags |= DFI_TYPE_NAME;

  if (!format_type (container, TREE_TYPE (type), basetype_info))
    ret = false;

  obstack_1grow (ob, '[');

  if (TYPE_DOMAIN (type) != NULL_TREE
      && TYPE_MAX_VALUE (TYPE_DOMAIN (type)) != NULL_TREE)
    {
      tree nelts = fold_build2 (PLUS_EXPR, sizetype,
				array_type_nelts (type),
				size_one_node);
      char buf[100];

      snprintf (buf, sizeof (buf), HOST_WIDE_INT_PRINT_DEC,
		tree_to_shwi (nelts));
      obstack_grow (ob, buf, strlen (buf));
    }
  else
    obstack_1grow (ob, '0');

  obstack_1grow (ob, ']');
  return ret;
}

/* Write the D version of vector TYPE to CONTAINER.TYPE_OBSTACK using INFO to
   control how the type is formatted.  Return true if the type can be
   represented in D, false otherwise.  */

static bool
format_vector_type (struct ddump_container &container, tree type,
		    format_info &info)
{
  struct obstack *ob = &container.type_obstack;
  bool ret = true;
  unsigned basetype_info_mask = (DFI_TYPE_NAME | (info.flags & DFI_CONST_QUAL));
  format_info basetype_info (basetype_info_mask);

  obstack_grow (ob, "__vector(", 9);
  if (!format_type (container, TREE_TYPE (type), basetype_info))
    ret = false;

  obstack_1grow (ob, '[');

  unsigned HOST_WIDE_INT nunits;
  if (TYPE_VECTOR_SUBPARTS (type).is_constant (&nunits))
    {
      char buf[100];

      snprintf (buf, sizeof (buf), HOST_WIDE_INT_PRINT_DEC, nunits);
      obstack_grow (ob, buf, strlen (buf));
    }
  else
    ret = false;

  obstack_grow (ob, "])", 2);
  return ret;
}

/* Write the D version of enumeral TYPE to CONTAINER.TYPE_OBSTACK using INFO to
   control how the type is formatted.  Return true if the type can be
   represented in D, false otherwise.  */

static bool
format_enumeral_type (struct ddump_container &container, tree type,
		      format_info &info)
{
  struct obstack *ob = &container.type_obstack;
  bool ret = true;

  if (TYPE_IDENTIFIER (type))
    container.decls_seen.add (TYPE_IDENTIFIER (type));

  /* Don't emit the body of an enum in a context where it isn't a valid D
     declaration.  */
  if (info.use_type_name ())
    {
      if (TYPE_IDENTIFIER (type))
	append_string (ob, TYPE_IDENTIFIER (type));
      else
	ret = false;

      return ret;
    }
  else if (info.is_anon_field_type ())
    {
      if (info.anon_type_name != NULL)
	ret = false;

      if (!format_integer_type (ob, type))
	ret = false;

      return ret;
    }

  obstack_grow (ob, "enum", 4);

  if (TYPE_IDENTIFIER (type) && !IDENTIFIER_ANON_P (TYPE_IDENTIFIER (type)))
    {
      obstack_1grow (ob, ' ');
      append_string (ob, TYPE_IDENTIFIER (type));
    }

  if (TREE_TYPE (type))
    {
      format_info basetype_info (DFI_TYPE_NAME | DFI_CONST_QUAL);

      obstack_grow (ob, " : ", 3);
      if (!format_type (container, TREE_TYPE (type), basetype_info))
	ret = false;
    }

  obstack_grow (ob, " { ", 3);

  for (tree element = TYPE_VALUES (type);
       element != NULL_TREE;
       element = TREE_CHAIN (element))
    {
      char buf[WIDE_INT_PRINT_BUFFER_SIZE];
      const char *name = IDENTIFIER_POINTER (TREE_PURPOSE (element));

      /* Sometimes a name will be defined as both an enum constant
	 and a macro.  Avoid duplicate definition errors by
	 removing the macro.  */
      struct macro_hash_value mhval;
      mhval.name = CONST_CAST (char *, name);
      mhval.value = NULL;

      void **slot = htab_find_slot (macro_hash, &mhval, NO_INSERT);
      if (slot != NULL)
	htab_clear_slot (macro_hash, slot);

      obstack_grow (ob, name, strlen (name));
      obstack_grow (ob, " = ", 3);

      tree value = TREE_VALUE (element);
      if (TREE_CODE (value) == CONST_DECL)
	value = DECL_INITIAL (value);

      if (tree_fits_shwi_p (value))
	snprintf (buf, sizeof (buf), HOST_WIDE_INT_PRINT_DEC,
		  tree_to_shwi (value));
      else if (tree_fits_uhwi_p (value))
	snprintf (buf, sizeof (buf), HOST_WIDE_INT_PRINT_UNSIGNED,
		  tree_to_uhwi (value));
      else
	print_hex (wi::to_wide (value), buf);

      obstack_grow (ob, buf, strlen (buf));
      if (TREE_CHAIN (element))
	obstack_1grow (ob, ',');

      obstack_1grow (ob, ' ');
    }

  obstack_1grow (ob, '}');
  return ret;
}

/* Write the D version of struct or union TYPE to CONTAINER.TYPE_OBSTACK using
   INFO to control how the type is formatted.  P_ART_I is used for indexing
   artifical elements in nested structures and should always be a NULL pointer
   when called, except by recursive calls from format_record_type() itself.
   Return true if the type can be represented in D, false otherwise.  */

static bool
format_record_type (struct ddump_container &container, tree type,
		    format_info &info, unsigned *p_art_i)
{
  struct obstack *ob = &container.type_obstack;
  bool ret = true;
  unsigned int art_i_dummy;

  if (p_art_i == NULL)
    {
      art_i_dummy = 0;
      p_art_i = &art_i_dummy;
    }

  /* FIXME: Why is this necessary?  Without it we can get a core
     dump on the s390x headers, or from a file containing simply
     "typedef struct S T;".  */
  layout_type (type);

  if (TYPE_IDENTIFIER (type))
    container.decls_seen.add (TYPE_IDENTIFIER (type));

  /* Don't emit the body of a struct/union in a context where it
     isn't a valid D declaration.  */
  if (info.use_type_name ())
    {
      if (TYPE_IDENTIFIER (type))
	append_string (ob, TYPE_IDENTIFIER (type));
      else
	ret = false;

      return ret;
    }

  const char *record_type
    = (TREE_CODE (type) == UNION_TYPE) ? "union" : "struct";
  obstack_grow (ob, record_type, strlen (record_type));
  if (TYPE_IDENTIFIER (type))
    {
      obstack_1grow (ob, ' ');
      append_string (ob, TYPE_IDENTIFIER (type));
    }
  else if (info.is_anon_field_type () && info.anon_type_name)
    {
      obstack_1grow (ob, ' ');
      obstack_grow (ob, info.anon_type_name, strlen (info.anon_type_name));
    }

  obstack_grow (ob, " { ", 3);

  for (tree field = TYPE_FIELDS (type); field != NULL_TREE;
       field = TREE_CHAIN (field))
    {
      if (TREE_CODE (field) != FIELD_DECL)
	continue;

      /* Bit fields are replaced by their representative field.  */
      if (DECL_BIT_FIELD_TYPE (field))
	{
	  if (integer_zerop (DECL_SIZE (field)))
	    continue;

	  tree repr = DECL_BIT_FIELD_REPRESENTATIVE (field);

	  while (TREE_CHAIN (field) != NULL_TREE
		 && DECL_BIT_FIELD_REPRESENTATIVE (TREE_CHAIN (field)) == repr)
	    field = TREE_CHAIN (field);

	  format_info field_info (DFI_TYPE_NAME | DFI_CONST_QUAL);
	  if (!format_type (container, TREE_TYPE (repr), field_info))
	    ret = false;

	  obstack_1grow (ob, ' ');
	  *p_art_i = append_artificial_bitfield (ob, *p_art_i);
	  obstack_grow (ob, "; ", 2);
	  continue;
	}

      /* Emit the field.  */
      tree field_type = TREE_TYPE (field);
      tree base_field_type = field_type;
      bool is_anon_field_type = false;

      while (POINTER_TYPE_P (base_field_type)
	     || TREE_CODE (base_field_type) == ARRAY_TYPE)
	base_field_type = TREE_TYPE (base_field_type);

      if ((AGGREGATE_TYPE_P (base_field_type)
	   || TREE_CODE (base_field_type) == ENUMERAL_TYPE)
	  && TYPE_IDENTIFIER (base_field_type) == NULL_TREE)
	is_anon_field_type = true;

      if (TYPE_USER_ALIGN (field_type))
	{
	  char buf[100];

	  snprintf (buf, sizeof (buf), "align(%u) ",
		    TYPE_ALIGN_UNIT (field_type));
	  obstack_grow (ob, buf, strlen (buf));
	}
      else if (TYPE_PACKED (field_type))
	obstack_grow (ob, "align(1) ", 9);

      if (is_anon_field_type)
	{
	  const char *type_name = NULL;
	  char buf[100];

	  /* Give anonymous types a fake type name.  */
	  if (RECORD_OR_UNION_TYPE_P (base_field_type)
	      && DECL_NAME (field) != NULL_TREE)
	    {
	      snprintf (buf, sizeof (buf), "__anonymous_type_%u", *p_art_i);
	      *p_art_i += 1;
	      type_name = buf;
	    }

	  format_info field_info (DFI_CONST_QUAL | DFI_ANON_FIELD,
				  type_name);

	  if (RECORD_OR_UNION_TYPE_P (field_type))
	    {
	      if (!format_record_type (container, field_type, field_info,
				       p_art_i))
		ret = false;
	    }
	  else if (INTEGRAL_TYPE_P (field_type)
		   || POINTER_TYPE_P (field_type)
		   || TREE_CODE (field_type) == ARRAY_TYPE)
	    {
	      if (DECL_NAME (field) == NULL_TREE)
		ret = false;

	      if (!format_type (container, field_type, field_info))
		ret = false;
	    }
	  else
	    ret = false;
	}
      else
	{
	  format_info field_info (DFI_TYPE_NAME | DFI_CONST_QUAL);

	  if (!format_type (container, field_type, field_info))
	    ret = false;
	}

      /* Emit the field name, but not for anonymous records and
	 unions.  */
      if (!is_anon_field_type || DECL_NAME (field) != NULL_TREE)
	{
	  obstack_1grow (ob, ' ');
	  append_decl_name (ob, field, container.keyword_hash);
	  obstack_grow (ob, "; ", 2);
	}
    }

  obstack_1grow (ob, '}');

  /* If an anonymous record or union type with a field name.  Put out the
     artifically generated name now.  */
  if (!TYPE_IDENTIFIER (type) && info.is_anon_field_type ())
    {
      obstack_1grow (ob, ' ');
      if (info.anon_type_name != NULL)
	obstack_grow (ob, info.anon_type_name, strlen (info.anon_type_name));
    }

  return ret;
}

/* Write the TYPE_ARG_TYPES of the function TYPE to CONTAINER.TYPE_OBSTACK.
   Return true if all arguments can be represented in D, false otherwise.  */

static bool
format_function_args (struct ddump_container &container, tree type)
{
  bool ret = true;
  struct obstack *ob = &container.type_obstack;
  bool seen_arg = false;
  format_info info (DFI_TYPE_NAME | DFI_REFERENCE | DFI_CONST_QUAL);
  tree arg_type;
  function_args_iterator iter;

  obstack_1grow (ob, '(');

  FOREACH_FUNCTION_ARGS (type, arg_type, iter)
    {
      if (VOID_TYPE_P (arg_type))
	break;

      if (seen_arg)
	obstack_grow (ob, ", ", 2);

      if (!format_type (container, arg_type, info))
	ret = false;

      seen_arg = true;
    }

  if (stdarg_p (type))
    {
      if (prototype_p (type))
	obstack_grow (ob, ", ", 2);

      obstack_grow (ob, "...", 3);
    }

  obstack_1grow (ob, ')');
  return ret;
}

/* Write the D version of function TYPE to CONTAINER.TYPE_OBSTACK using INFO to
   control how the type is formatted.  Return true if the type can be
   represented in D, false otherwise.  */

static bool
format_function_type (struct ddump_container &container, tree type,
		      format_info &info)
{
  struct obstack *ob = &container.type_obstack;
  bool ret = true;

  /* D has no way to write a type which is a function but not a
     pointer to a function.  */
  if (!info.is_func_ok ())
    ret = false;

  unsigned return_info_mask
    = (DFI_TYPE_NAME | DFI_REFERENCE | (info.flags & DFI_CONST_QUAL));
  format_info return_info (return_info_mask);

  if (!format_type (container, TREE_TYPE (type), return_info))
    ret = false;

  obstack_1grow (ob, ' ');
  obstack_grow (ob, "function", 8);

  if (!format_function_args (container, type))
    ret = false;

  return ret;
}

/* Write the D version of TYPE to CONTAINER.TYPE_OBSTACK using INFO to control
   how the type is formatted.  P_ART_I is used for indexing artifical elements
   in nested structures and should always be a NULL pointer when called, except
   by certain recursive calls from format_type() itself.
   IS_ANON_RECORD_OR_UNION is true the type is an anonymous field type.
   Return true if the type can be represented in D, false otherwise.  */

static bool
format_type (struct ddump_container &container, tree type, format_info &info)
{
  bool ret = true;
  struct obstack *ob = &container.type_obstack;

  /* Shortcut formatting the type if TYPE_NAME is both and set and requested.
     If the type was used in a typedef, it will use the alias instead of
     writing out the base type.  */
  if (info.use_type_name ()
      && TYPE_NAME (type) != NULL_TREE
      && (TREE_CODE (TYPE_NAME (type)) != TYPE_DECL
	  || !DECL_IS_UNDECLARED_BUILTIN (TYPE_NAME (type)))
      && (container.decls_seen.contains (type)
	  || container.decls_seen.contains (TYPE_NAME (type)))
      )
    {
      tree name = TYPE_IDENTIFIER (type);

      if (htab_find_slot (container.invalid_hash, IDENTIFIER_POINTER (name),
			  NO_INSERT) != NULL)
	ret = false;

      append_string (ob, name);
      return ret;
    }

  container.decls_seen.add (type);

  switch (TREE_CODE (type))
    {
    case INTEGER_TYPE:
      ret = format_integer_type (ob, type);
      break;

    case REAL_TYPE:
      ret = format_real_type (ob, type);
      break;

    case COMPLEX_TYPE:
      ret = format_complex_type (ob, type);
      break;

    case BOOLEAN_TYPE:
      obstack_grow (ob, "bool", 4);
      break;

    case VOID_TYPE:
      obstack_grow (ob, "void", 4);
      break;

    case POINTER_TYPE:
      ret = format_pointer_type (container, type, info);
      break;

    case REFERENCE_TYPE:
      ret = format_reference_type (container, type, info);
      break;

    case ARRAY_TYPE:
      ret = format_array_type (container, type, info);
      break;

    case VECTOR_TYPE:
      ret = format_vector_type (container, type, info);
      break;

    case ENUMERAL_TYPE:
      ret = format_enumeral_type (container, type, info);
      break;

    case RECORD_TYPE:
    case UNION_TYPE:
      ret = format_record_type (container, type, info, NULL);
      break;

    case FUNCTION_TYPE:
      ret = format_function_type (container, type, info);
      break;

    default:
      obstack_grow (ob, "INVALID-type", 12);
      ret = false;
      break;
    }

  return ret;
}

static void
output_location (location_t loc)
{
  expanded_location xloc = expand_location (loc);
  fprintf (d_dump_file, "#line %d \"%s\"\n", xloc.line, xloc.file);
}

/* Output the type which was built on the type obstack, and then free
   it.  */

static void
output_type (struct ddump_container &container)
{
  struct obstack *ob = &container.type_obstack;
  obstack_1grow (ob, '\0');
  fputs ((char *) obstack_base (ob), d_dump_file);
  obstack_free (ob, obstack_base (ob));
}

/* Output a function declaration.  */

static void
output_fndecl (struct ddump_container &container, tree decl)
{
  struct obstack *ob = &container.type_obstack;
  bool is_valid = true;
  char buf[100];

  tree decl_name = DECL_NAME (decl);
  tree decl_asm_name = DECL_ASSEMBLER_NAME (decl);

  if (decl_asm_name != decl_name
      || htab_find_slot (container.keyword_hash,
			 IDENTIFIER_POINTER (decl_name), NO_INSERT))
    {
      const char *asm_name = IDENTIFIER_POINTER (decl_asm_name);
      if (*asm_name == '*')
	asm_name++;

      snprintf (buf, sizeof (buf), "pragma(mangle, \"%s\") ", asm_name);
      obstack_grow (ob, buf, strlen (buf));
    }

  format_info info (DFI_TYPE_NAME | DFI_REFERENCE | DFI_CONST_QUAL);
  if (!format_type (container, TREE_TYPE (TREE_TYPE (decl)), info))
    is_valid = false;

  obstack_1grow (ob, ' ');
  append_decl_name (ob, decl, container.keyword_hash);

  if (!format_function_args (container, TREE_TYPE (decl)))
    is_valid = false;

  output_location (DECL_SOURCE_LOCATION (decl));

  if (!is_valid)
    fprintf (d_dump_file, "// ");

  output_type (container);
  fprintf (d_dump_file, ";\n");
}

/* Returns true if DECL is an implicitly generated TYPE_DECL for a type.
   These do not require an alias to be declared in D.  */

static bool
is_implicit_typedef (const_tree decl)
{
  if (DECL_NAME (decl) == NULL_TREE)
    return true;

  if (DECL_ARTIFICIAL (decl)
      && TYPE_STUB_DECL (TREE_TYPE (decl)) == decl)
    return true;

  return false;
}

/* Output a typedef or something like a struct definition.  */

static void
output_typedef (struct ddump_container &container, tree decl)
{
  if (!is_implicit_typedef (decl))
    {
      const char *ident = IDENTIFIER_POINTER (DECL_NAME (decl));

      /* If type is a keyword, skip.  */
      if (htab_find_slot (container.keyword_hash, ident, NO_INSERT) != NULL)
	return;

      /* If type defined already, skip.  */
      void **slot = htab_find_slot (container.type_hash, ident, INSERT);
      if (*slot != NULL)
	return;

      *slot = CONST_CAST (void *, (const void *) ident);

      tree type = TREE_TYPE (decl);
      format_info info (DFI_CONST_QUAL);

      if (is_tagged_type (type))
	{
	  /* If this is a plain typedef, and not a typedef struct, then only get
	     the type name for the alias declaration.  */
	  if (TYPE_NAME (type) == decl
	      && DECL_ORIGINAL_TYPE (decl) != NULL_TREE
	      && TYPE_NAME (DECL_ORIGINAL_TYPE (decl)) != NULL_TREE)
	    {
	      type = DECL_ORIGINAL_TYPE (decl);
	      info.flags |= DFI_TYPE_NAME;

	      /* The typedef can be to an opaque struct or union, so is a
		 potential dummy type.  */
	      const char *ident = IDENTIFIER_POINTER (TYPE_IDENTIFIER (type));
	      container.pot_dummy_types.add (ident);
	    }
	}
      else
	info.flags |= DFI_TYPE_NAME;

      /* Allow FUNCTION_TYPE types to be emitted as typedefs.  */
      if (TREE_CODE (type) == FUNCTION_TYPE)
	info.flags |= DFI_FUNCTION;

      output_location (DECL_SOURCE_LOCATION (decl));

      if (!format_type (container, type, info))
	{
	  fprintf (d_dump_file, "// ");
	  slot = htab_find_slot (container.invalid_hash, ident, INSERT);
	  *slot = CONST_CAST (void *, (const void *) ident);
	}

      if (info.use_type_name ())
	{
	  fprintf (d_dump_file, "alias %s = ",
		   IDENTIFIER_POINTER (DECL_NAME (decl)));
	}

      output_type (container);
      container.decls_seen.add (decl);

      if (info.use_type_name ())
	fprintf (d_dump_file, ";");
    }
  else if (RECORD_OR_UNION_TYPE_P (TREE_TYPE (decl)))
    {
      tree type = TREE_TYPE (decl);
      const char *ident = IDENTIFIER_POINTER (TYPE_IDENTIFIER (type));

       /* If type defined already, skip.  */
       void **slot = htab_find_slot (container.type_hash, ident, INSERT);
       if (*slot != NULL)
	 return;

       *slot = CONST_CAST (void *, (const void *) ident);

       output_location (DECL_SOURCE_LOCATION (decl));

       format_info info (DFI_CONST_QUAL);
       if (!format_type (container, type, info))
	 {
	   fprintf (d_dump_file, "// ");
	   slot = htab_find_slot (container.invalid_hash, ident, INSERT);
	   *slot = CONST_CAST (void *, (const void *) ident);
	 }

       output_type (container);
    }
  else if (TREE_CODE (TREE_TYPE (decl)) == ENUMERAL_TYPE)
    {
      tree type = TREE_TYPE (decl);
      bool is_anon_enum = (TYPE_IDENTIFIER (type) == NULL_TREE
			   || IDENTIFIER_ANON_P (TYPE_IDENTIFIER (type)));
      const char *ident = NULL;
      void **slot;

      if (!is_anon_enum)
	{
	  ident = IDENTIFIER_POINTER (TYPE_IDENTIFIER (type));

	  /* If type defined already, skip.  */
	  slot = htab_find_slot (container.type_hash, ident, INSERT);
	  if (*slot != NULL)
	    return;

	  *slot = CONST_CAST (void *, (const void *) ident);
	}

      output_location (DECL_SOURCE_LOCATION (decl));

      format_info info (DFI_CONST_QUAL);
      if (!format_type (container, type, info))
	{
	  fprintf (d_dump_file, "// ");
	  if (ident)
	    {
	      slot = htab_find_slot (container.invalid_hash, ident, INSERT);
	      *slot = CONST_CAST (void *, (const void *) ident);
	    }
	}

      output_type (container);
    }
  else
    return;

  fprintf (d_dump_file, "\n");
}

/* Output a variable.  */

static void
output_var (struct ddump_container &container, tree decl)
{
  bool is_valid;

  if (container.decls_seen.contains (decl)
      || container.decls_seen.contains (DECL_NAME (decl)))
    return;

  container.decls_seen.add (decl);
  container.decls_seen.add (DECL_NAME (decl));

  tree type_name = TYPE_NAME (TREE_TYPE (decl));
  tree id = NULL_TREE;

  if (type_name != NULL_TREE && TREE_CODE (type_name) == IDENTIFIER_NODE)
    id = type_name;
  else if (type_name != NULL_TREE && TREE_CODE (type_name) == TYPE_DECL
	   && !DECL_IS_UNDECLARED_BUILTIN (type_name) && DECL_NAME (type_name))
    id = DECL_NAME (type_name);

  if (id != NULL_TREE
      && (!htab_find_slot (container.type_hash, IDENTIFIER_POINTER (id),
			   NO_INSERT)
	  || htab_find_slot (container.invalid_hash, IDENTIFIER_POINTER (id),
			     NO_INSERT)))
    id = NULL_TREE;

  if (id != NULL_TREE)
    {
      struct obstack *ob = &container.type_obstack;

      append_string (ob, id);
      is_valid = htab_find_slot (container.type_hash, IDENTIFIER_POINTER (id),
				 NO_INSERT) != NULL;
    }
  else
    {
      format_info info (DFI_TYPE_NAME | DFI_CONST_QUAL);
      is_valid = format_type (container, TREE_TYPE (decl), info);
    }

  if (is_valid
      && htab_find_slot (container.type_hash,
			 IDENTIFIER_POINTER (DECL_NAME (decl)),
			 NO_INSERT) != NULL)
    {
      /* There is already a type with this name, probably from a
	 struct tag.  Prefer the type to the variable.  */
      is_valid = false;
    }

  output_location (DECL_SOURCE_LOCATION (decl));

  if (!is_valid)
    fprintf (d_dump_file, "// ");

  fprintf (d_dump_file, "__gshared ");
  output_type (container);
  fprintf (d_dump_file, " %s;\n", IDENTIFIER_POINTER (DECL_NAME (decl)));

  /* Sometimes an extern variable is declared with an unknown struct
     type.  */
  if (type_name != NULL_TREE && RECORD_OR_UNION_TYPE_P (TREE_TYPE (decl)))
    {
      if (TREE_CODE (type_name) == IDENTIFIER_NODE)
	container.pot_dummy_types.add (IDENTIFIER_POINTER (type_name));
      else if (TREE_CODE (type_name) == TYPE_DECL)
	container.pot_dummy_types.add
			    (IDENTIFIER_POINTER (DECL_NAME (type_name)));
    }
}

/* Output the final value of a preprocessor macro or enum constant.
   This is called via htab_traverse_noresize.  */

static int
print_macro (void **slot, void *arg)
{
  struct macro_hash_value *mhval = (struct macro_hash_value *) *slot;
  struct ddump_container *container = (struct ddump_container *) arg;

  fprintf (d_dump_file, "enum ");

  if (htab_find_slot (container->keyword_hash, mhval->name, NO_INSERT) != NULL)
    fprintf (d_dump_file, "_");

  fprintf (d_dump_file, "%s = %s;\n", mhval->name, mhval->value);

  return 1;
}

/* Build a hash table with the D keywords.  */

const char * const keywords[] = {
  /* Basic types.  */
  "void", "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong",
  "cent", "ucent", "float", "double", "real", "ifloat", "idouble", "ireal",
  "cfloat", "cdouble", "creal", "char", "wchar", "dchar", "bool",
  /* Aggregates.  */
  "struct", "class", "interface", "union", "enum", "import", "alias",
  "override", "delegate", "function", "mixin", "align", "extern", "private",
  "protected", "public", "export", "static", "final", "const", "abstract",
  "debug", "deprecated", "inout", "lazy", "auto", "package", "immutable",
  /* Statements.  */
  "if", "else", "while", "for", "do", "switch", "case", "default", "break",
  "continue", "with", "synchronized", "return", "goto", "try", "catch",
  "finally", "asm", "foreach", "foreach_reverse", "scope",
  /* Contracts.  */
  "invariant", "in", "out", "body",
  /* Operators.  */
  "is", "this", "super",
  /* Testing.  */
  "unittest",
  /* Literals.  */
  "__LINE__", "__FILE__", "__MODULE__", "__FUNCTION__", "__PRETTY_FUNCTION__",
  "__DATE__", "__TIME__", "__TIMESTAMP__", "__VENDOR__", "__VERSION__",
  "__EOF__",
  /* Other.  */
  "cast", "null", "assert", "true", "false", "throw", "new", "delete",
  "version", "module", "template", "typeof", "pragma", "typeid",
  "ref", "__traits", "pure", "nothrow", "__gshared", "shared",
};

static void
keyword_hash_init (struct ddump_container &container)
{
  size_t count = sizeof (keywords) / sizeof (keywords[0]);

  for (size_t i = 0; i < count; i++)
    {
      void **slot = htab_find_slot (container.keyword_hash,
				    keywords[i], INSERT);
      *slot = CONST_CAST (void *, (const void *) keywords[i]);
    }
}

/* Traversing the pot_dummy_types and seeing which types are present
   in the global types hash table and creating dummy definitions if
   not found.  This function is invoked by hash_set::traverse.  */

static bool
find_dummy_types (const char *const &ptr, ddump_container *adata)
{
  struct ddump_container *data = (struct ddump_container *) adata;
  const char *type = (const char *) ptr;

  void **slot = htab_find_slot (data->type_hash, type, NO_INSERT);
  void **islot = htab_find_slot (data->invalid_hash, type, NO_INSERT);
  if (slot == NULL || islot != NULL)
    fprintf (d_dump_file, "struct %s;\n", type);

  return true;
}

/* Output symbols.  */

static void
finish (const char *filename)
{
  struct ddump_container container;
  unsigned int ix;
  tree decl;

  real_debug_hooks->finish (filename);

  container.type_hash = htab_create (100, htab_hash_string,
				     string_hash_eq, NULL);
  container.invalid_hash = htab_create (10, htab_hash_string,
					string_hash_eq, NULL);
  container.keyword_hash = htab_create (100, htab_hash_string,
					string_hash_eq, NULL);
  obstack_init (&container.type_obstack);

  keyword_hash_init (container);

  FOR_EACH_VEC_SAFE_ELT (queue, ix, decl)
    {
      switch (TREE_CODE (decl))
	{
	case FUNCTION_DECL:
	  output_fndecl (container, decl);
	  break;

	case TYPE_DECL:
	  output_typedef (container, decl);
	  break;

	case VAR_DECL:
	  output_var (container, decl);
	  break;

	default:
	  gcc_unreachable ();
	}
    }

  htab_traverse_noresize (macro_hash, print_macro, &container);

  /* To emit dummy definitions.  */
  container.pot_dummy_types.traverse<ddump_container *, find_dummy_types>
			(&container);

  htab_delete (container.type_hash);
  htab_delete (container.invalid_hash);
  htab_delete (container.keyword_hash);
  obstack_free (&container.type_obstack, NULL);

  vec_free (queue);

  if (fclose (d_dump_file) != 0)
    error ("could not close D dump file: %m");

  d_dump_file = NULL;
}

} // namespace d_dump_spec

/* Set up our hooks.  */

const struct gcc_debug_hooks *
dump_d_spec_init (const char *filename, const struct gcc_debug_hooks *hooks)
{
  d_dump_file = fopen (filename, "w");
  if (d_dump_file == NULL)
    {
      error ("could not open D dump file %qs: %m", filename);
      return hooks;
    }

  d_debug_hooks = *hooks;
  real_debug_hooks = hooks;

  d_debug_hooks.finish = d_dump_spec::finish;
  d_debug_hooks.define = d_dump_spec::define;
  d_debug_hooks.undef = d_dump_spec::undef;
  d_debug_hooks.function_decl = d_dump_spec::function_decl;
  d_debug_hooks.early_global_decl = d_dump_spec::early_global_decl;
  d_debug_hooks.late_global_decl = d_dump_spec::late_global_decl;
  d_debug_hooks.type_decl = d_dump_spec::type_decl;

  macro_hash = htab_create (100, macro_hash_hashval, macro_hash_eq,
			    macro_hash_del);

  return &d_debug_hooks;
}

#include "gt-d-dump-spec.h"
