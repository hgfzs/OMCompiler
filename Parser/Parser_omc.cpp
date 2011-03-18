/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2010, Link�pings University,
 * Department of Computer and Information Science,
 * SE-58183 Link�ping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF THIS OSMC PUBLIC
 * LICENSE (OSMC-PL). ANY USE, REPRODUCTION OR DISTRIBUTION OF
 * THIS PROGRAM CONSTITUTES RECIPIENT'S ACCEPTANCE OF THE OSMC
 * PUBLIC LICENSE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from Link�pings University, either from the above address,
 * from the URL: http://www.ida.liu.se/projects/OpenModelica
 * and in the OpenModelica distribution.
 *
 * This program is distributed  WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS
 * OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

extern "C" {

#include "meta_modelica.h"
#include "rml_compatibility.h"
#include "parse.c"

void* Parser_parse(const char* filename)
{
  void *res = parseFile(filename,PARSE_MODELICA);
  if (res == NULL)
    MMC_THROW();
  // printAny(res);
  return res;
}

void* Parser_parseexp(const char* filename)
{
  void *res = parseFile(filename,PARSE_EXPRESSION);
  if (res == NULL)
    MMC_THROW();
  return res;
}

void* Parser_parsestring(const char* data, const char** msg)
{
  ErrorImpl__setCheckpoint("parsestring");
  void *res = parseString(data,PARSE_MODELICA);
  if (res != NULL) {
    *msg = "Ok";
    ErrorImpl__rollBack("parsestring");
    return res;
  } else {
    *msg = ErrorImpl__rollBackAndPrint("parsestring");
    return NULL; // FIXME?!
  }
}

void* Parser_parsestringexp(const char* data, const char** msg)
{
  ErrorImpl__setCheckpoint("parsestringexp");
  void *res = parseString(data,PARSE_EXPRESSION);
  if (res != NULL) {
    *msg = "Ok";
    ErrorImpl__rollBack("parsestringexp");
    return res;
  } else {
    *msg = ErrorImpl__rollBackAndPrint("parsestringexp");
    return NULL; // FIXME?!
  }
}

}
