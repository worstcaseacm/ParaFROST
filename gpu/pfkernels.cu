
#include "pfdevice.cuh"

template<class T>
__global__ void memset_k(T* mem, T val, size_t sz)
{
	size_t i = blockDim.x * blockIdx.x + threadIdx.x;
	while (i < sz) { mem[i] = val; i += blockDim.x * gridDim.x; }
}

__global__ void reset_ot_k(OT* ot)
{
	int64 v = blockDim.x * blockIdx.x + threadIdx.x;
	while (v < ot->size()) { (*ot)[v].clear(); v += blockDim.x * gridDim.x; }
}

__global__ void reduce_ot_k(CNF* cnf, OT* ot)
{
	int64 v = blockDim.x * blockIdx.x + threadIdx.x;
	while (v < ot->size()) { 
		OL& ol = (*ot)[v];
		if (ol.size()) {
			int idx = 0, ol_sz = ol.size();
			while (idx < ol_sz) {
				if ((*cnf)[ol[idx]].status() == DELETED) ol[idx] = ol[--ol_sz];
				else idx++;
			}
			ol.resize(ol_sz);
		}
		v += blockDim.x * gridDim.x; 
	}
}

__global__ void create_ot_k(CNF* cnf, OT* ot)
{
	uint32 i = blockDim.x * blockIdx.x + threadIdx.x;
	while (i < cnf->size()) {
		SCLAUSE& c = (*cnf)[i];
		if (c.status() == ORIGINAL || c.status() == LEARNT) {
#pragma unroll
			for (LIT_POS l = 0; l < c.size(); l++) (*ot)[c[l]].insert(i);
		}
		i += blockDim.x * gridDim.x;
	}
}

__global__ void assign_scores(OCCUR* occurs, SCORE* scores, uint32* hist, uint32 size)
{
	uint32 v = blockDim.x * blockIdx.x + threadIdx.x;
	while (v < size) {
		uint32 p = V2D(v + 1), n = NEG(p);
		uint32 ps = hist[p], ns = hist[n];
		occurs[v].ps = ps, occurs[v].ns = ns;
		scores[v].v = v;
		scores[v].sc = (!ps || !ns) ? (ps | ns) : (ps * ns);
		v += blockDim.x * gridDim.x;
	}
}

__global__ void calc_sig_k(CNF* cnf, uint32 offset, uint32 size)
{
	uint32 i = blockDim.x * blockIdx.x + threadIdx.x + offset;
	while (i < size) { (*cnf)[i].calcSig(); i += blockDim.x * gridDim.x; }
}

__global__ void copy_k(uint32* dest, CNF* src, int64 size)
{
	int64 i = blockDim.x * blockIdx.x + threadIdx.x;
	int64 stride = blockDim.x * gridDim.x;
	while (i < size) { dest[i] = *src->data(i); i += stride; }
}

__global__ void copy_if_k(uint32* dest, CNF* src, GSTATS* gstats)
{
	uint32 i = blockDim.x * blockIdx.x + threadIdx.x;
	uint32 stride = blockDim.x * gridDim.x;
	while (i < src->size()) {
		SCLAUSE& c = (*src)[i];
		if (c.status() == ORIGINAL || c.status() == LEARNT) {
			uint64 lits_idx = atomicAdd(&gstats->numLits, c.size());
#pragma unroll
			for (LIT_POS l = 0; l < c.size(); l++) dest[lits_idx++] = c[l];
		}
		i += stride;
	}
}

__global__ void calc_added_cls_k(CNF* cnf, OT* ot, cuVecU* pVars, GSTATS* gstats)
{
	uint32* sh_rCls = SharedMemory<uint32>();
	uint32 v = blockIdx.x * (blockDim.x << 1) + threadIdx.x;
	uint32 stride = (blockDim.x << 1) * gridDim.x;
	uint32 x, p, n, nCls = 0;
	while (v < pVars->size()) {
		x = (*pVars)[v], p = V2D(x + 1), n = NEG(p);
		calcResolvents(x + 1, *cnf, (*ot)[p], (*ot)[n], nCls);
		if (v + blockDim.x < pVars->size()) {
			x = (*pVars)[v + blockDim.x], p = V2D(x + 1), n = NEG(p);
			calcResolvents(x + 1, *cnf, (*ot)[p], (*ot)[n], nCls);
		}
		v += stride;
	}
	loadShared(sh_rCls, nCls, pVars->size());
	sharedReduce(sh_rCls, nCls);
	warpReduce(sh_rCls, nCls);
	if (threadIdx.x == 0) atomicAdd(&gstats->numClauses, nCls);
}

__global__ void calc_added_all_k(CNF* cnf, OT* ot, cuVecU* pVars, GSTATS* gstats)
{
	uint32* sh_rCls = SharedMemory<uint32>();
	uint64* sh_rLits = (uint64*)(sh_rCls + blockDim.x);
	uint32 v = blockIdx.x * (blockDim.x << 1) + threadIdx.x;
	uint32 stride = (blockDim.x << 1) * gridDim.x;
	uint32 x, p, n, nCls = 0;
	uint64 nLits = 0;
	while (v < pVars->size()) {
		x = (*pVars)[v], p = V2D(x + 1), n = NEG(p);
		calcResolvents(x + 1, *cnf, (*ot)[p], (*ot)[n], nCls, nLits);
		if (v + blockDim.x < pVars->size()) {
			x = (*pVars)[v + blockDim.x], p = V2D(x + 1), n = NEG(p);
			calcResolvents(x + 1, *cnf, (*ot)[p], (*ot)[n], nCls, nLits);
		}
		v += stride;
	}
	loadShared(sh_rCls, nCls, sh_rLits, nLits, pVars->size());
	sharedReduce(sh_rCls, nCls, sh_rLits, nLits);
	warpReduce(sh_rCls, nCls, sh_rLits, nLits);
	if (threadIdx.x == 0) {
		atomicAdd(&gstats->numClauses, nCls);
		atomicAdd(&gstats->numLits, nLits);
	}
}

__global__ void cnt_del_vars(GSTATS* gstats, uint32 size)
{
	uint32* sh_delVars = SharedMemory<uint32>();
	uint32 i = blockIdx.x * (blockDim.x << 1) + threadIdx.x;
	uint32 stride = (blockDim.x << 1) * gridDim.x;
	uint32 nDelVars = 0;
	while (i < size) {
		if (!gstats->seen[i]) nDelVars++;
		if (i + blockDim.x < size && !gstats->seen[i + blockDim.x]) nDelVars++;
		i += stride;
	}
	loadShared(sh_delVars, nDelVars, size);
	sharedReduce(sh_delVars, nDelVars);
	warpReduce(sh_delVars, nDelVars);
	if (threadIdx.x == 0) atomicAdd(&gstats->numDelVars, nDelVars);
}

__global__ void cnt_reds(CNF* cnf, GSTATS* gstats)
{
	uint32* sh_rCls = SharedMemory<uint32>();
	uint64* sh_rLits = (uint64*)(sh_rCls + blockDim.x);
	uint32 i = blockIdx.x * (blockDim.x << 1) + threadIdx.x;
	uint32 stride = (blockDim.x << 1) * gridDim.x;
	uint32 nCls = 0;
	uint64 nLits = 0;
	while (i < cnf->size()) {
		SCLAUSE& c1 = (*cnf)[i], &c2 = (*cnf)[i + blockDim.x];
		if (c1.status() == LEARNT || c1.status() == ORIGINAL) {
			CL_LEN cl_size = c1.size();
			nCls++, nLits += cl_size;
			for (LIT_POS k = 0; k < cl_size; k++) { assert(c1[k]); gstats->seen[V2X(c1[k])] = 1; }
		}
		if (i + blockDim.x < cnf->size() && (c2.status() == LEARNT || c2.status() == ORIGINAL)) {
			CL_LEN cl_size = c2.size();
			nCls++, nLits += cl_size;
			for (LIT_POS k = 0; k < cl_size; k++) { assert(c2[k]); gstats->seen[V2X(c2[k])] = 1; }
		}
		i += stride;
	}
	loadShared(sh_rCls, nCls, sh_rLits, nLits, cnf->size());
	sharedReduce(sh_rCls, nCls, sh_rLits, nLits);
	warpReduce(sh_rCls, nCls, sh_rLits, nLits);
	if (threadIdx.x == 0) {
		atomicAdd(&gstats->numClauses, nCls);
		atomicAdd(&gstats->numLits, nLits);
	}
}

__global__ void cnt_lits(CNF* cnf, GSTATS* gstats)
{
	uint64* sh_rLits = SharedMemory<uint64>();
	uint32 i = blockIdx.x * (blockDim.x << 1) + threadIdx.x;
	uint32 stride = (blockDim.x << 1) * gridDim.x;
	uint64 nLits = 0;
	while (i < cnf->size()) {
		SCLAUSE& c1 = (*cnf)[i], &c2 = (*cnf)[i + blockDim.x];
		if (c1.status() == LEARNT || c1.status() == ORIGINAL) nLits += c1.size();
		if (i + blockDim.x < cnf->size() && (c2.status() == LEARNT || c2.status() == ORIGINAL)) nLits += c2.size();
		i += stride;
	}
	loadShared(sh_rLits, nLits, cnf->size());
	sharedReduce(sh_rLits, nLits);
	warpReduce(sh_rLits, nLits);
	if (threadIdx.x == 0) atomicAdd(&gstats->numLits, nLits);
}

__global__ void cnt_cls_lits(CNF* cnf, GSTATS* gstats)
{
	uint32* sh_rCls = SharedMemory<uint32>();
	uint64* sh_rLits = (uint64*)(sh_rCls + blockDim.x);
	uint32 i = blockIdx.x * (blockDim.x << 1) + threadIdx.x;
	uint32 stride = (blockDim.x << 1) * gridDim.x;
	uint32 nCls = 0;
	uint64 nLits = 0;
	while (i < cnf->size()) {
		SCLAUSE& c1 = (*cnf)[i], &c2 = (*cnf)[i + blockDim.x];
		if (c1.status() == LEARNT || c1.status() == ORIGINAL) { nCls++, nLits += c1.size(); }
		if (i + blockDim.x < cnf->size() && 
			(c2.status() == LEARNT || c2.status() == ORIGINAL)) { nCls++, nLits += c2.size(); }
		i += stride;
	}
	loadShared(sh_rCls, nCls, sh_rLits, nLits, cnf->size());
	sharedReduce(sh_rCls, nCls, sh_rLits, nLits);
	warpReduce(sh_rCls, nCls, sh_rLits, nLits);
	if (threadIdx.x == 0) {
		atomicAdd(&gstats->numClauses, nCls);
		atomicAdd(&gstats->numLits, nLits);
	}
}

__global__ void ve_k(CNF *cnf, OT* ot, cuVecU* pVars, GSOL* sol)
{
	uint32 tx = threadIdx.x;
	uint32 v = blockDim.x * blockIdx.x + threadIdx.x;
	__shared__ uint32 defs[BLSIMP * FAN_LMT];
	__shared__ uint32 outs[BLSIMP * MAX_SH_RES_LEN];
	while (v < pVars->size()) {
		uint32 x = (*pVars)[v], p = V2D(x + 1), n = NEG(p);
		assert(sol->value[x] == UNDEFINED);
		if ((*ot)[p].size() == 0 || (*ot)[n].size() == 0) { // pure
			deleteClauses(*cnf, (*ot)[p], (*ot)[n]);
			sol->value[x] = (*ot)[p].size() ? 1 : 0;
			(*ot)[p].clear(true), (*ot)[n].clear(true);
		}
		else if ((*ot)[p].size() == 1 || (*ot)[n].size() == 1) {
			resolve_x(x + 1, *cnf, (*ot)[p], (*ot)[n], sol, &outs[tx * MAX_SH_RES_LEN]);
			sol->value[x] = 1;
			(*ot)[p].clear(true), (*ot)[n].clear(true);
		}
		else if (gateReasoning_x(p, *cnf, (*ot)[p], (*ot)[n], sol, &defs[tx * FAN_LMT], &outs[tx * MAX_SH_RES_LEN])
			  || resolve_x(x + 1, *cnf, (*ot)[p], (*ot)[n], sol, &outs[tx * MAX_SH_RES_LEN], true)) {
			sol->value[x] = 1;
			(*ot)[p].clear(true), (*ot)[n].clear(true);
		}
		v += blockDim.x * gridDim.x;
	}
}

__global__ void hse_k(CNF *cnf, OT* ot, cuVecU* pVars, GSOL* sol)
{
	uint32 v = blockDim.x * blockIdx.x + threadIdx.x;
	__shared__ uint32 sh_cls[BLSIMP * SH_MAX_HSE_IN];
	while (v < pVars->size()) {
		assert(sol->value[pVars->at(v)] == UNDEFINED);
		uint32 p = V2D(pVars->at(v) + 1), n = NEG(p);
		self_sub_x(p, *cnf, (*ot)[p], (*ot)[n], sol, &sh_cls[threadIdx.x * SH_MAX_HSE_IN]);
		v += blockDim.x * gridDim.x;
	}
}

__global__ void bce_k(CNF *cnf, OT* ot, cuVecU* pVars, GSOL* sol)
{
	uint32 v = blockDim.x * blockIdx.x + threadIdx.x;
	__shared__ uint32 sh_cls[BLSIMP * SH_MAX_BCE_IN];
	while (v < pVars->size()) {
		uint32 x = (*pVars)[v], p = V2D(x + 1), n = NEG(p);
		assert(sol->value[x] == UNDEFINED);
		blocked_x(x + 1, *cnf, (*ot)[p], (*ot)[n], &sh_cls[threadIdx.x * SH_MAX_BCE_IN]);
		v += blockDim.x * gridDim.x;
	}
}

__global__ void hre_k(CNF *cnf, OT* ot, cuVecU* pVars, GSOL* sol)
{
	uint32 v = blockDim.y * blockIdx.y + threadIdx.y;
	uint32* smem = SharedMemory<uint32>();
	uint32* m_c = smem + warpSize * SH_MAX_HRE_IN + threadIdx.y * SH_MAX_HRE_OUT; // shared memory for resolvent
	while (v < pVars->size()) {
		assert(sol->value[pVars->at(v)] == UNDEFINED);
		uint32 p = V2D(pVars->at(v) + 1);
		OL& poss = (*ot)[p], &negs = (*ot)[NEG(p)];
		// do merging and apply forward equality check (on-the-fly) over resolvents
#pragma unroll
		for (uint32 i = 0; i < poss.size(); i++) {
			if ((*cnf)[poss[i]].status() == DELETED) continue;
			uint32 pos_size = (*cnf)[poss[i]].size();
			if (pos_size <= SH_MAX_HRE_IN) { // use shared memory for positives
				uint32* sh_pos = smem + threadIdx.y * SH_MAX_HRE_IN;
				if (threadIdx.x == 0) (*cnf)[poss[i]].shareTo(sh_pos);
#pragma unroll
				for (uint32 j = 0; j < negs.size(); j++) {
					SCLAUSE& neg = (*cnf)[negs[j]];
					if (neg.status() == DELETED || (pos_size + neg.size() - 2) > SH_MAX_HRE_OUT) continue;
					CL_LEN m_c_size = 0;
					uint32 m_c_sig = 0;
					if (threadIdx.x == 0) {
						assert(warpSize == blockDim.x);
						m_c_size = merge(pVars->at(v) + 1, sh_pos, pos_size, neg, m_c);
						calcSig(m_c, m_c_size, m_c_sig);
					}
					m_c_size = __shfl_sync(0xffffffff, m_c_size, 0);
					m_c_sig = __shfl_sync(0xffffffff, m_c_sig, 0);
					forward_equ(*cnf, *ot, m_c, m_c_sig, m_c_size);
				}
			}
			else { // use global memory
#pragma unroll
				for (uint32 j = 0; j < negs.size(); j++) {
					SCLAUSE& neg = (*cnf)[negs[j]];
					if (neg.status() == DELETED || (pos_size + neg.size() - 2) > SH_MAX_HRE_OUT) continue;
					CL_LEN m_c_size = 0;
					uint32 m_c_sig = 0;
					if (threadIdx.x == 0) {
						assert(warpSize == blockDim.x);
						m_c_size = merge(pVars->at(v) + 1, (*cnf)[poss[i]], neg, m_c);
						calcSig(m_c, m_c_size, m_c_sig);
					}
					m_c_size = __shfl_sync(0xffffffff, m_c_size, 0);
					m_c_sig = __shfl_sync(0xffffffff, m_c_sig, 0);
					forward_equ(*cnf, *ot, m_c, m_c_sig, m_c_size);
				} 
			} 
		} 
		v += blockDim.y * gridDim.y;
	}
}

__global__ void prop_k(CNF* cnf, OT* ot, cuVecU* pVars, GSOL* sol)
{
	
}

#if BCP_DBG
void prop(CNF* cnf, OT* ot, cuVecU* pVars, GSOL* sol)
{
	while (sol->head < sol->assigns->size()) { // propagate units
		uint32 assign = sol->assigns->at(sol->head), assign_idx = V2X(assign), f_assign = FLIP(assign);
		assert(assign > 0);
		LIT_ST assign_val = !ISNEG(assign);
		if (sol->value[assign_idx] != assign_val) { // not propagated before
			assert(sol->value[assign_idx] == UNDEFINED);
			sol->value[assign_idx] = assign_val;
			//printf("c | Propagating assign("), pLit(assign), printf("):\n"), pClauseSet(*cnf, (*ot)[assign]), pClauseSet(*cnf, (*ot)[f_assign]);
			deleteClauseSet(*cnf, (*ot)[assign]); // remove satisfied
			for (uint32 i = 0; i < (*ot)[f_assign].size(); i++) { // reduce unsatisfied 
				SCLAUSE& c = (*cnf)[(*ot)[f_assign][i]];
				assert(c.size());
				if (c.status() == DELETED || propClause(sol, c, f_assign)) continue; // clause satisfied
				if (c.size() == 0) return; // conflict on top level
				if (c.size() == 1) {
					assert(*c > 1);
					if (sol->value[V2X(*c)] == UNDEFINED) sol->assigns->_push(*c); // new unit
					else return;  // conflict on top level
				}
			}
			//pClauseSet(*cnf, (*ot)[assign]), pClauseSet(*cnf, (*ot)[f_assign]);
			(*ot)[assign].clear(true), (*ot)[f_assign].clear(true);
		}
		sol->head++;
	}
	// discard propagated variables
	uint32 n = 0;
	for (uint32 v = 0; v < pVars->size(); v++) {
		uint32 x = pVars->at(v);
		if (sol->value[x] == UNDEFINED) (*pVars)[n++] = x;
	}
	pVars->resize(n);
}
#endif
//==============================================//
//          ParaFROST Wrappers/helpers          //
//==============================================//
void mem_set(addr_t mem, const Byte& val, const size_t& size)
{
	int nBlocks = MIN((size + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	memset_k<Byte> << <nBlocks, BLOCK1D >> > (mem, val, size);
	LOGERR("Memory set failed");
	CHECK(cudaDeviceSynchronize());
}
void mem_set(LIT_ST* mem, const LIT_ST& val, const size_t& size)
{
	int nBlocks = MIN((size + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	memset_k<LIT_ST> << <nBlocks, BLOCK1D >> > (mem, val, size);
	LOGERR("Memory set failed");
	CHECK(cudaDeviceSynchronize());
}
void copy(uint32* dest, CNF* src, const int64& size)
{
	int nBlocks = MIN((size + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	copy_k << <nBlocks, BLOCK1D >> > (dest, src, size);
	LOGERR("Copying failed");
	CHECK(cudaDeviceSynchronize());
}
void copyIf(uint32* dest, CNF* src, GSTATS* gstats)
{
	gstats->numLits = 0;
	int nBlocks = MIN((nClauses() + maxAddedCls() + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	copy_if_k << <nBlocks, BLOCK1D >> > (dest, src, gstats);
	LOGERR("Copying failed");
	CHECK(cudaDeviceSynchronize());
}
void calc_vscores(OCCUR* occurs, SCORE* scores, uint32* histogram)
{
	int nBlocks = MIN((nOrgVars() + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	assign_scores << <nBlocks, BLOCK1D >> > (occurs, scores, histogram, nOrgVars());
	LOGERR("Assigning scores failed");
	CHECK(cudaDeviceSynchronize());
}
void calc_added(CNF* cnf, OT* ot, PV* pv, GSTATS* gstats)
{
	assert(pv->numPVs > 0);
	gstats->numClauses = 0;
	int nBlocks = MIN((pv->numPVs + (BLUB << 1) - 1) / (BLUB << 1), maxGPUThreads / (BLUB << 1));
	int smemSize = BLUB * sizeof(uint32);
	calc_added_cls_k << <nBlocks, BLUB, smemSize >> > (cnf, ot, pv->pVars, gstats);
	LOGERR("Added clauses calculation failed");
	CHECK(cudaDeviceSynchronize());
	cnf_stats.max_added_cls = gstats->numClauses;
	cnf_stats.max_added_lits = cnf_stats.max_added_cls * MAX_GL_RES_LEN;
	printf("c | added cls = %d\n", maxAddedCls()), printf("c | added lits = %zd\n", maxAddedLits());
}
void calc_sig(CNF* cnf, const uint32& offset, const uint32& size)
{
	int nBlocks = MIN((size + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	calc_sig_k << <nBlocks, BLOCK1D >> > (cnf, offset, size);
	LOGERR("Calculating signatures failed");
	CHECK(cudaDeviceSynchronize());
}
void create_ot(CNF* cnf, OT* ot, const bool& p)
{
	assert(cnf != NULL);
	assert(ot != NULL);
	int rstGridSize = MIN((V2D(nOrgVars() + 1) + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	int otGridSize = MIN((nClauses() + maxAddedCls() + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	reset_ot_k << <rstGridSize, BLOCK1D >> > (ot);
	create_ot_k << <otGridSize, BLOCK1D >> > (cnf, ot);
	LOGERR("Occurrence table creation failed");
	CHECK(cudaDeviceSynchronize());
	assert(ot->accViolation());
	if (p) {
		cout << "c |==========================|" << endl;
		cout << "c |==== occurrence table ====|" << endl;
		ot->print();
		cout << "c |==========================|" << endl;
	}
}
void reduce_ot(CNF* cnf, OT* ot, const bool& p)
{
	assert(cnf != NULL);
	assert(ot != NULL);
	int nBlocks = MIN((V2D(nOrgVars() + 1) + BLOCK1D - 1) / BLOCK1D, maxGPUThreads / BLOCK1D);
	reduce_ot_k << <nBlocks, BLOCK1D >> > (cnf, ot);
	LOGERR("Occurrence table reduction failed");
	CHECK(cudaDeviceSynchronize());
	assert(ot->accViolation());
	if (p) {
		cout << "c |==========================|" << endl;
		cout << "c |==== occurrence table ====|" << endl;
		ot->print();
		cout << "c |==========================|" << endl;
	}
}
CNF_STATE ve(CNF *cnf, OT* ot, PV *pv)
{   
	assert(pv->numPVs > 0);
	int nBlocks = MIN((pv->numPVs + BLSIMP - 1) / BLSIMP, maxGPUThreads / BLSIMP);
#if VE_DBG
	ve_k << <1, 1 >> > (cnf, ot, pv->pVars, pv->sol);
#else
	ve_k << <nBlocks, BLSIMP >> > (cnf, ot, pv->pVars, pv->sol);
#endif
#if BCP_DBG
	CHECK(cudaDeviceSynchronize());
	prop(cnf, ot, pv->pVars, pv->sol);
#else
	prop_k << <1, 1 >> > (cnf, ot, pv->sol);
#endif
	LOGERR("Parallel BVE failed");
	CHECK(cudaDeviceSynchronize());
	if (pv->sol->head < pv->sol->assigns->size()) return UNSAT;
	pv->numPVs = pv->pVars->size();
	return UNSOLVED;
}
CNF_STATE hse(CNF *cnf, OT* ot, PV *pv)
{
	assert(pv->numPVs > 0);
	int nBlocks = MIN((pv->numPVs + BLSIMP - 1) / BLSIMP, maxGPUThreads / BLSIMP);
#if SS_DBG
	hse_k << <1, 1 >> > (cnf, ot, pv->pVars, pv->sol);
#else
	hse_k << <nBlocks, BLSIMP >> > (cnf, ot, pv->pVars, pv->sol);
#endif
#if BCP_DBG
	CHECK(cudaDeviceSynchronize());
	prop(cnf, ot, pv->pVars, pv->sol);
#else
	prop_k << <1, 1 >> > (cnf, ot, pv->sol);
#endif
	LOGERR("Parallel HSE failed");
	CHECK(cudaDeviceSynchronize());
	if (pv->sol->head < pv->sol->assigns->size()) return UNSAT;
	pv->numPVs = pv->pVars->size();
	return UNSOLVED;
}
void bce(CNF *cnf, OT* ot, PV *pv)
{
	assert(pv->numPVs > 0);
	int nBlocks = MIN((pv->numPVs + BLSIMP - 1) / BLSIMP, maxGPUThreads / BLSIMP);
	bce_k << <nBlocks, BLSIMP >> > (cnf, ot, pv->pVars, pv->sol);
	LOGERR("Parallel BCE failed");
	CHECK(cudaDeviceSynchronize());
}
void hre(CNF *cnf, OT* ot, PV *pv)
{
	assert(pv->numPVs > 0);
	dim3 block2D(devProp.warpSize, devProp.warpSize), grid2D(1, 1, 1);
	grid2D.y = MIN((pv->numPVs + block2D.y - 1) / block2D.y, maxGPUThreads / block2D.y);
	int smemSize = devProp.warpSize * (SH_MAX_HRE_IN + SH_MAX_HRE_OUT) * sizeof(uint32);
	hre_k << <grid2D, block2D, smemSize >> > (cnf, ot, pv->pVars, pv->sol);
	LOGERR("HRE Elimination failed");
	CHECK(cudaDeviceSynchronize());
}
void evalReds(CNF* cnf, GSTATS* gstats)
{
	gstats->numDelVars = 0;
	gstats->numClauses = 0;
	gstats->numLits = 0;
	mem_set(gstats->seen, 0, nOrgVars());
	uint32 cnf_sz = nClauses() + maxAddedCls();
	int nBlocks1 = MIN((cnf_sz + (BLOCK1D << 1) - 1) / (BLOCK1D << 1), maxGPUThreads / (BLOCK1D << 1));
	int nBlocks2 = MIN((nOrgVars() + (BLOCK1D << 1) - 1) / (BLOCK1D << 1), maxGPUThreads / (BLOCK1D << 1));
	int smemSize1 = BLOCK1D * (sizeof(uint64) + sizeof(uint32));
	int smemSize2 = BLOCK1D * sizeof(uint32);
	cnt_reds << <nBlocks1, BLOCK1D, smemSize1 >> > (cnf, gstats);
	cnt_del_vars << <nBlocks2, BLOCK1D, smemSize2 >> > (gstats, nOrgVars());
	LOGERR("Counting reductions failed");
	CHECK(cudaDeviceSynchronize());
	cnf_stats.n_del_vars = gstats->numDelVars;
	cnf_stats.n_cls_after = gstats->numClauses;
	cnf_stats.n_lits_after = gstats->numLits;
}
void countLits(CNF* cnf, GSTATS* gstats)
{
	gstats->numLits = 0;
	uint32 cnf_sz = nClauses() + maxAddedCls();
	int nBlocks = MIN((cnf_sz + (BLOCK1D << 1) - 1) / (BLOCK1D << 1), maxGPUThreads / (BLOCK1D << 1));
	int smemSize = BLOCK1D * sizeof(uint64);
	cnt_lits << <nBlocks, BLOCK1D, smemSize >> > (cnf, gstats);
	LOGERR("Counting literals failed");
	CHECK(cudaDeviceSynchronize());
	cnf_stats.n_lits_after = gstats->numLits;
}
void countCls(CNF* cnf, GSTATS* gstats)
{
	gstats->numClauses = 0;
	gstats->numLits = 0;
	uint32 cnf_sz = nClauses() + maxAddedCls();
	int nBlocks = MIN((cnf_sz + (BLOCK1D << 1) - 1) / (BLOCK1D << 1), maxGPUThreads / (BLOCK1D << 1));
	int smemSize = BLOCK1D * (sizeof(uint64) + sizeof(uint32));
	cnt_cls_lits << <nBlocks, BLOCK1D, smemSize >> > (cnf, gstats);
	LOGERR("Counting clauses-literals failed");
	CHECK(cudaDeviceSynchronize());
	cnf_stats.n_cls_after = gstats->numClauses;
	cnf_stats.n_lits_after = gstats->numLits;
}