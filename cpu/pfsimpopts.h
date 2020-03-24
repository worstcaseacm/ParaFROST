/***********************************************************************
Copyright(c) 2020, Muhammad Osama - Anton Wijs,
Technische Universiteit Eindhoven (TU/e).

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
************************************************************************/

#ifndef __SIMP_OPTS_
#define __SIMP_OPTS_

#include "pfargs.h"

BOOL_OPT opt_simp_perf_en("perf-simp", "print simplifier full performance report", true);
BOOL_OPT opt_ve_en("bve", "enable bounded variable elimination (BVE)", true);
BOOL_OPT opt_sub_en("sub", "enable hybrid subsumption elimination (HSE) with high bounds in LCVE", false);
BOOL_OPT opt_ve_plus_en("bve+", "enable (BVE + HSE) untill no literals can be removed", true);
BOOL_OPT opt_bce_en("bce", "enable blocked clause elimination", false);
BOOL_OPT opt_hre_en("hre", "enable hidden redundancy elimination", false);
BOOL_OPT opt_all_en("all", "enable all simplifications", false);
INT_OPT opt_mu_pos("mu-pos", "set the positive freezing temperature in LCVE", 32, INT32R(10, INT32_MAX));
INT_OPT opt_mu_neg("mu-neg", "set the negative freezing temperature in LCVE", 32, INT32R(10, INT32_MAX));
INT_OPT opt_phases("phases", "set the number of phases in stage-1 reductions", 2, INT32R(0, INT32_MAX));
INT_OPT opt_cnf_free("cnf-free-freq", "set the frequency of CNF memory shrinkage in SIGmA", 3, INT32R(0, 5));

#endif