#!/usr/bin/env python

from distutils.core import setup

setup( name         = "pecoff-checksum"
     , version      = "0.0.0"
     , package_dir  = {"" : "src"}
     , scripts      = ["src/pecoff-checksum"]
     )
