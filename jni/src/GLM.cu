#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <stdio.h>
#include <MatKernel.hpp>

typedef float (*fntype)(float);
typedef float (*optype)(float,float);

__device__ float link_linear(float a) {return a;}
__device__ float link_logistic(float a) {return log(a/(1.0f - a));}

__device__ float mean_linear(float a) {return a;}
__device__ float mean_logistic(float a) {
  if (a > 20.0f) {
    return 1.0f;
  } else if (a < -80.0f) {
    return 0.0f;
  } else {
    return 1.0f/(1.0f + exp(-a));
  }
}

__device__ float deriv_linear(float a, float b) {return b-a;}
__device__ float deriv_logistic(float a, float b) {return b-a;}
__device__ float deriv_maxp(float p, float t) {return (2.0f*t - 1.0f)*p*(1.0f-p);}
__device__ float deriv_svm(float p, float t) {
  float tt = 2 * t - 1;
  return (p * tt < 1.0f) ? tt : 0.0f;
}


#define EPS 1.0e-10f
__device__ float ll_linear(float a, float t) {return (t-a)*(a-t);}
__device__ float ll_logistic(float a, float b) {return log(a * b + (1.0f - a) * (1.0f - b) + EPS);}
__device__ float ll_maxp(float a, float t) {return a * t + (1.0f - a) * (1.0f - t) - 1.0f;}
__device__ float ll_svm(float p, float t) {
  float tt = 2 * t - 1;
  return min(0.0f, tt * p - 1);
}

__device__ const fntype linkfns[] = {
  link_linear,
  link_logistic,
  link_logistic,
  link_linear};

__device__ const fntype meanfns[] = {
  mean_linear,
  mean_logistic,
  mean_logistic,
  mean_linear};

__device__ const optype derivfns[] = {
  deriv_linear,
  deriv_logistic,
  deriv_maxp,
  deriv_svm};

__device__ const optype llfns[] = {
  ll_linear,
  ll_logistic,
  ll_maxp,
  ll_svm};


typedef double (*dfntype)(double);
typedef double (*doptype)(double,double);

__device__ double dlink_linear(double a) {return a;}
__device__ double dlink_logistic(double a) {return log(a/(1.0 - a));}

__device__ double dmean_linear(double a) {return a;}
__device__ double dmean_logistic(double a) {
  double tmp;
  if (a > 0) {
    tmp = exp(-a);
    return 1.0/(1.0 + tmp);
  } else {
    tmp = exp(a);
    return tmp/(1.0 + tmp);
  }
}

__device__ double dderiv_linear(double a, double b) {return b-a;}
__device__ double dderiv_logistic(double a, double b) {return b-a;}
__device__ double dderiv_maxp(double p, double t) {return (2.0*t - 1.0f)*p*(1.0-p);}
__device__ double dderiv_svm(double p, double t) {
  double tt = 2 * t - 1;
  return (p * tt < 1.0) ? tt : 0.0;
}


__device__ double dll_linear(double a, double t) {return (t-a)*(a-t);}
__device__ double dll_logistic(double a, double b) {return log(a * b + (1.0 - a) * (1.0 - b) + EPS);}
__device__ double dll_maxp(double a, double t) {return a * t + (1.0 - a) * (1.0 - t) - 1.0;}
__device__ double dll_svm(double p, double t) {
  double tt = 2 * t - 1;
  return min(0.0, tt * p - 1);
}

__device__ const dfntype dlinkfns[] = {
  dlink_linear,
  dlink_logistic,
  dlink_logistic,
  dlink_linear};

__device__ const dfntype dmeanfns[] = {
  dmean_linear,
  dmean_logistic,
  dmean_logistic,
  dmean_linear};

__device__ const doptype dderivfns[] = {
  dderiv_linear,
  dderiv_logistic,
  dderiv_maxp,
  dderiv_svm};

__device__ const doptype dllfns[] = {
  dll_linear,
  dll_logistic,
  dll_maxp,
  dll_svm};


void setsizes(int N, dim3 *gridp, int *nthreadsp) {
  int nblocks = 1;
  int nthreads = 1;
  while (nblocks * nthreads < N) {
    if (nblocks < 16) {
      nblocks = 2*nblocks;
    } else if (nthreads < 1024) {
      nthreads = 2*nthreads;
    } else {
      nblocks = 2*nblocks;
    }
  }
  gridp->y = 1 + (nblocks-1)/65536;
  gridp->x = 1 + (nblocks-1)/gridp->y;
  gridp->z = 1;
  *nthreadsp = nthreads;
}

__global__ void __apply_preds(float *A, int *L, float *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    fntype fn = meanfns[L[i % nrows]];
    C[i] = fn(A[i]);
  }
}

int apply_preds(float *A, int *L, float *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_preds<<<griddims,nthreads>>>(A, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __apply_links(float *A, int *L, float *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    fntype fn = linkfns[L[i % nrows]];
    C[i] = fn(A[i]);
  }
}

int apply_links(float *A, int *L, float *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_links<<<griddims,nthreads>>>(A, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __apply_lls(float *A, float *B, int *L, float *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    optype op = llfns[L[i % nrows]];
    C[i] = op(A[i],B[i]);
  }
}


int apply_lls(float *A, float *B, int *L, float *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_lls<<<griddims,nthreads>>>(A, B, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __apply_derivs(float *A, float *B, int *L, float *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    optype op = derivfns[L[i % nrows]];
    C[i] = op(A[i],B[i]);
  }
}

int apply_derivs(float *A, float *B, int *L, float *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_derivs<<<griddims,nthreads>>>(A, B, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __apply_dpreds(double *A, int *L, double *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    dfntype fn = dmeanfns[L[i % nrows]];
    C[i] = fn(A[i]);
  }
}

int apply_dpreds(double *A, int *L, double *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_dpreds<<<griddims,nthreads>>>(A, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __apply_dlinks(double *A, int *L, double *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    dfntype fn = dlinkfns[L[i % nrows]];
    C[i] = fn(A[i]);
  }
}

int apply_dlinks(double *A, int *L, double *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_dlinks<<<griddims,nthreads>>>(A, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __apply_dlls(double *A, double *B, int *L, double *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    doptype op = dllfns[L[i % nrows]];
    C[i] = op(A[i],B[i]);
  }
}


int apply_dlls(double *A, double *B, int *L, double *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_dlls<<<griddims,nthreads>>>(A, B, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __apply_dderivs(double *A, double *B, int *L, double *C, int nrows, int ncols) {
  int ip = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  for (int i = ip; i < nrows*ncols; i += blockDim.x * gridDim.x * gridDim.y) {
    doptype op = dderivfns[L[i % nrows]];
    C[i] = op(A[i],B[i]);
  }
}

int apply_dderivs(double *A, double *B, int *L, double *C, int nrows, int ncols) {
  int nthreads;
  dim3 griddims;
  setsizes(nrows*ncols, &griddims, &nthreads);
  __apply_dderivs<<<griddims,nthreads>>>(A, B, L, C, nrows, ncols);
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__forceinline__ __device__ void __gupdate(float grad, int i, int ihere, int jhere, float *MM, float *Sumsq, float *Mask, int maskrows, float *lrate, int lrlen, 
                                          float *vexp, int vexplen, float *texp, int texplen, float istep, int addgrad, float epsilon) {
  float lr, ve, te, pve, ste, ngrad;
  Sumsq[ihere] += grad * grad + epsilon;
  if (addgrad) {
    lr =  (lrlen > 1) ? lrate[i] : lrate[0];
    ve =  (vexplen > 1) ? vexp[i] : vexp[0];
    te =  (texplen > 1) ? texp[i] : texp[0];
    pve = (ve == 0) ? 1.0f : pow(Sumsq[ihere] * istep, ve);
    ste = pow(istep, te);
    ngrad = grad * lr * ste / pve;
    atomicAdd(&MM[ihere], ngrad);
  }
  if (Mask != NULL) {
    if (maskrows > 1) {
      if (Mask[ihere] == 0) MM[ihere] = 0;
    } else {
      if (Mask[jhere] == 0) MM[ihere] = 0;
    }
  }
}


__global__ void __multADAGrad(int nrows, int ncols, int nnz, float *A, float *Bdata, int *Bir, int *Bic, float *MM, 
                              float *Sumsq, float *Mask, int maskrows, float *lrate, int lrlen, float *vexp, int vexplen, 
                              float *texp, int texplen, float istep, int addgrad, float epsilon, int biasv, int nbr) {
  float aval, grad;
  int i, j, ihere, jhere;
  int jstart = ((long long)blockIdx.x) * nnz / gridDim.x;
  int jend = ((long long)(blockIdx.x + 1)) * nnz / gridDim.x;
  if (biasv > 0) {
    for (i = threadIdx.x; i < nrows; i += blockDim.x) {
      aval = 0;
      for (j = jstart; j < jend ; j++) {
        if (j == jstart || Bic[j-1] != Bic[j]) {
          aval = A[i + nrows * Bic[j]];
          grad = aval;
          ihere = i + nrows * nbr;
          jhere = nbr;
          __gupdate(grad, i, ihere, jhere, MM, Sumsq, Mask, maskrows, lrate, lrlen, vexp, vexplen, texp, texplen, istep, addgrad, epsilon);
        }
        grad = aval * Bdata[j];
        ihere = i + nrows * Bir[j];
        jhere = Bir[j];
        __gupdate(grad, i, ihere, jhere, MM, Sumsq, Mask, maskrows, lrate, lrlen, vexp, vexplen, texp, texplen, istep, addgrad, epsilon);
      }
    } 
  } else {
    for (i = threadIdx.x; i < nrows; i += blockDim.x) {
      aval = 0;
      for (j = jstart; j < jend ; j++) {
        if (j == jstart || Bic[j-1] != Bic[j]) {
          aval = A[i + nrows * Bic[j]];
        }
        grad = aval * Bdata[j];
        ihere = i + nrows * Bir[j];
        jhere = Bir[j];
        __gupdate(grad, i, ihere, jhere, MM, Sumsq, Mask, maskrows, lrate, lrlen, vexp, vexplen, texp, texplen, istep, addgrad, epsilon);
      }
    } 
  }
}

__global__ void __multADAGradx(int nrows, int ncols, int nnz, float *A, float *Bdata, int *Bir, int *Bic, float *MM, 
                               float *Sumsq, float *Mask, int maskrows, float *lrate, int lrlen, float *vexp, int vexplen, 
                               float *texp, int texplen, float istep, int addgrad, float epsilon, int biasv, int nbr) {
  float aval, grad;
  int i, j, ihere, jhere;
  int bid = threadIdx.y + blockDim.y * blockIdx.x;
  int nb = blockDim.y * gridDim.x;
  int jstart = ((long long)bid) * nnz / nb;
  int jend = ((long long)(bid + 1)) * nnz / nb;
  i = threadIdx.x;
  aval = 0;
  if (biasv > 0) {
    for (j = jstart; j < jend ; j++) {
      if (j == jstart || Bic[j-1] != Bic[j]) {
        aval = A[i + nrows * Bic[j]];
        grad = aval;
        ihere = i + nrows * nbr;
        jhere = nbr;
        __gupdate(grad, i, ihere, jhere, MM, Sumsq, Mask, maskrows, lrate, lrlen, vexp, vexplen, texp, texplen, istep, addgrad, epsilon);
      }
      grad = aval * Bdata[j];
      ihere = i + nrows * Bir[j];
      jhere = Bir[j];
      __gupdate(grad, i, ihere, jhere, MM, Sumsq, Mask, maskrows, lrate, lrlen, vexp, vexplen, texp, texplen, istep, addgrad, epsilon);
    }
  } else {
    for (j = jstart; j < jend ; j++) {
      if (j == jstart || Bic[j-1] != Bic[j]) {
        aval = A[i + nrows * Bic[j]];
      }
      grad = aval * Bdata[j];
      ihere = i + nrows * Bir[j];
      jhere = Bir[j];
      __gupdate(grad, i, ihere, jhere, MM, Sumsq, Mask, maskrows, lrate, lrlen, vexp, vexplen, texp, texplen, istep, addgrad, epsilon);
    }
  }
}

int multADAGrad(int nrows, int ncols, int nnz, float *A, float *Bdata, int *Bir, int *Bic, float *MM, 
                float *Sumsq, float *Mask, int maskrows, float *lrate, int lrlen, float *vexp, int vexplen, 
                float *texp, int texplen, float istep, int addgrad, float epsilon, int biasv, int nbr) {
  if (nrows < 128) {
    int nt = max(1, min(ncols/2, 256/nrows));
    dim3 threadDim(nrows, nt, 1);
    int nblocks = min(256, max(1, 1 + (ncols-1)/nt));
    __multADAGradx<<<nblocks,threadDim>>>(nrows, ncols, nnz, A, Bdata, Bir, Bic, MM, Sumsq, Mask, maskrows, lrate, lrlen,
                                          vexp, vexplen, texp, texplen, istep, addgrad, epsilon, biasv, nbr);
  } else {
    int nthreads = min(1024, 32*(1+(nrows-1)/32));
    int nblocks = min(128, ncols);
    __multADAGrad<<<nblocks,nthreads>>>(nrows, ncols, nnz, A, Bdata, Bir, Bic, MM, Sumsq, Mask, maskrows, lrate, lrlen,
                                        vexp, vexplen, texp, texplen, istep, addgrad, epsilon, biasv, nbr);
  }
  cudaDeviceSynchronize();
  cudaError_t err = cudaGetLastError();
  return err;
}

__global__ void __nrandinit(curandState *rstates) {
  int id = threadIdx.x + blockDim.x * blockIdx.x;
  curand_init(1234, id, 0, &rstates[id]);
}

__global__ void __ADAGrad(int nrows, int ncols, float *mm, float *um, float *ssq, float *mask, int maskr, float nw, float *ve, int nve, 
                          float *ts, int nts, float *lr, int nlr, float langevin, float eps, int doupdate, curandState *rstates) {
  int ithread = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  int nthreads = blockDim.x * gridDim.x * gridDim.y;
  int i, irow, icol;
  float mmval, umval, sqval, newss, veval, tsval, lrval, denom, grad;
  float sqnw = sqrtf(nw);
  float sq1mnw = sqrtf(1-nw);
  curandState *prstate = &rstates[ithread];
  for (i = ithread; i < nrows*ncols; i += nthreads) {
    icol = i / nrows;
    irow = i - icol * nrows;
    umval = um[i];
    sqval = ssq[i];
//    newss = (nw * umval * umval) + (1 - nw) * sqval;
    newss = hypotf(sqnw * umval, sq1mnw * sqval);
    ssq[i] = newss;
    if (doupdate) {
      mmval = mm[i];
      veval = (nve > 1) ? ve[irow] : ve[0];
      tsval = (nts > 1) ? ts[irow] : ts[0];
      lrval = (nlr > 1) ? lr[irow] : lr[0];
      denom = (veval == 0.5f) ? newss : powf(newss, veval*2);
      denom = denom + eps;
      grad = (umval / denom);
      if (langevin > 0) grad += curand_normal(prstate) * langevin;
      mmval += grad * lrval * tsval;
      if (maskr > 0) {
        if (maskr > 1) {
          mmval *= mask[i]; 
        } else {
          mmval *= mask[icol];
        }
      }
      mm[i] = mmval;
    }
  }
}

// ADAGRAD with standard momentum

__global__ void __ADAGradm(int nrows, int ncols, float *mm, float *um, float *ssq, float *momentum, float mu, float *mask, int maskr,
			   float nw, float *ve, int nve, float *ts, int nts, float *lr, int nlr, float langevin, float eps, int doupdate, curandState *rstates) {
  int ithread = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  int nthreads = blockDim.x * gridDim.x * gridDim.y;
  int i, irow, icol;
  float mmval, umval, sqval, newss, veval, tsval, lrval, denom, grad;
  float sqnw = sqrtf(nw);
  float sq1mnw = sqrtf(1-nw);
  curandState *prstate = &rstates[ithread];
  for (i = ithread; i < nrows*ncols; i += nthreads) {
    icol = i / nrows;
    irow = i - icol * nrows;
    umval = um[i];
    sqval = ssq[i];
//    newss = (nw * umval * umval) + (1 - nw) * sqval;
    newss = hypotf(sqnw * umval, sq1mnw * sqval);
    ssq[i] = newss;
    if (doupdate) {
      mmval = mm[i];
      veval = (nve > 1) ? ve[irow] : ve[0];
      tsval = (nts > 1) ? ts[irow] : ts[0];
      lrval = (nlr > 1) ? lr[irow] : lr[0];
      denom = (veval == 0.5f) ? newss : powf(newss, veval*2);
      denom = denom + eps;
      grad = (umval / denom);
      if (langevin > 0) grad += curand_normal(prstate) * langevin;
      grad = grad * lrval * tsval;               // Normal gradient
      grad += momentum[i];                       // With momentum
      momentum[i] = mu * grad;                   // Save updated momentum
      mmval += grad;                             // Add the new gradient
      if (maskr > 0) {
        if (maskr > 1) {
          mmval *= mask[i]; 
        } else {
          mmval *= mask[icol];
        }
      }
      mm[i] = mmval;
    }
  }
}

// ADAGRAD with Nesterov momentum

__global__ void __ADAGradn(int nrows, int ncols, float *mm, float *um, float *ssq, float *momentum, float mu, float *mask, int maskr,
			   float nw, float *ve, int nve, float *ts, int nts, float *lr, int nlr, float langevin, float eps, int doupdate, curandState *rstates) {
  int ithread = threadIdx.x + blockDim.x * (blockIdx.x + gridDim.x * blockIdx.y);
  int nthreads = blockDim.x * gridDim.x * gridDim.y;
  int i, irow, icol;
  float mmval, umval, sqval, newss, veval, tsval, lrval, denom, grad, oldmom, newmom;
  float sqnw = sqrtf(nw);
  float sq1mnw = sqrtf(1-nw);
  curandState *prstate = &rstates[ithread];
  for (i = ithread; i < nrows*ncols; i += nthreads) {
    icol = i / nrows;
    irow = i - icol * nrows;
    umval = um[i];
    sqval = ssq[i];
//    newss = (nw * umval * umval) + (1 - nw) * sqval;
    newss = hypotf(sqnw * umval, sq1mnw * sqval);
    ssq[i] = newss;
    if (doupdate) {
      mmval = mm[i];
      veval = (nve > 1) ? ve[irow] : ve[0];
      tsval = (nts > 1) ? ts[irow] : ts[0];
      lrval = (nlr > 1) ? lr[irow] : lr[0];
      denom = (veval == 0.5f) ? newss : powf(newss, veval*2);
      denom = denom + eps;
      grad = (umval / denom);
      if (langevin > 0) grad += curand_normal(prstate) * langevin;
      grad = grad * lrval * tsval;               // Normal gradient
      oldmom = momentum[i];                      // Momentum
      grad += oldmom;                            // New gradient
      newmom = mu * grad;                        // Compute new momentum
      momentum[i] = newmom;                      // Save new momentum
      mmval += grad + newmom - oldmom;
      if (maskr > 0) {
        if (maskr > 1) {
          mmval *= mask[i]; 
        } else {
          mmval *= mask[icol];
        }
      }
      mm[i] = mmval;
    }
  }
}

int ADAGrad(int nrows, int ncols, float *mm, float *um, float *ssq, float *mask, int maskr, float nw, float *ve, int nve, float *ts, int nts,
	    float *lrate, int nlrate, float langevin, float eps, int doupdate) {
  int nthreads;
  dim3 griddims;
  int basesize;
  if (langevin > 0) {
    basesize = max(32, nrows * ncols / 32);
  } else {
    basesize = max(32, nrows * ncols);
  }
  setsizes(basesize, &griddims, &nthreads);
  int ntt = nthreads * griddims.x * griddims.y;
  curandState *rstates = NULL;
  if (langevin > 0) {
    cudaError_t err = cudaMalloc(( void **)& rstates , ntt * sizeof(curandState));
    if (err > 0) {
      fprintf(stderr, "Error in cudaMalloc %d", err);
      return err;
    }
    cudaDeviceSynchronize();
    __nrandinit<<<griddims,nthreads>>>(rstates); 
    cudaDeviceSynchronize();
  }
  __ADAGrad<<<griddims,nthreads>>>(nrows, ncols, mm, um, ssq, mask, maskr, nw, ve, nve, ts, nts, lrate, nlrate, langevin, eps, doupdate, rstates);
  cudaDeviceSynchronize();
  if (langevin > 0)   cudaFree(rstates);
  cudaError_t err = cudaGetLastError();
  return err;
}

int ADAGradm(int nrows, int ncols, float *mm, float *um, float *ssq, float *momentum, float mu, float *mask, int maskr, float nw, float *ve, int nve, float *ts, int nts,
	    float *lrate, int nlrate, float langevin, float eps, int doupdate) {
  int nthreads;
  dim3 griddims;
  int basesize;
  if (langevin > 0) {
    basesize = max(32, nrows * ncols / 32);
  } else {
    basesize = max(32, nrows * ncols);
  }
  setsizes(basesize, &griddims, &nthreads);
  int ntt = nthreads * griddims.x * griddims.y;
  curandState *rstates = NULL;
  if (langevin > 0) {
    cudaError_t err = cudaMalloc(( void **)& rstates , ntt * sizeof(curandState));
    if (err > 0) {
      fprintf(stderr, "Error in cudaMalloc %d", err);
      return err;
    }
    cudaDeviceSynchronize();
    __nrandinit<<<griddims,nthreads>>>(rstates); 
    cudaDeviceSynchronize();
  }
  __ADAGradm<<<griddims,nthreads>>>(nrows, ncols, mm, um, ssq, momentum, mu, mask, maskr, nw, ve, nve, ts, nts, lrate, nlrate, langevin, eps, doupdate, rstates);
  cudaDeviceSynchronize();
  if (langevin > 0)   cudaFree(rstates);
  cudaError_t err = cudaGetLastError();
  return err;
}

int ADAGradn(int nrows, int ncols, float *mm, float *um, float *ssq, float *momentum, float mu, float *mask, int maskr, float nw, float *ve, int nve, float *ts, int nts,
	    float *lrate, int nlrate, float langevin, float eps, int doupdate) {
  int nthreads;
  dim3 griddims;
  int basesize;
  if (langevin > 0) {
    basesize = max(32, nrows * ncols / 32);
  } else {
    basesize = max(32, nrows * ncols);
  }
  setsizes(basesize, &griddims, &nthreads);
  int ntt = nthreads * griddims.x * griddims.y;
  curandState *rstates = NULL;
  if (langevin > 0) {
    cudaError_t err = cudaMalloc(( void **)& rstates , ntt * sizeof(curandState));
    if (err > 0) {
      fprintf(stderr, "Error in cudaMalloc %d", err);
      return err;
    }
    cudaDeviceSynchronize();
    __nrandinit<<<griddims,nthreads>>>(rstates); 
    cudaDeviceSynchronize();
  }
  __ADAGradn<<<griddims,nthreads>>>(nrows, ncols, mm, um, ssq, momentum, mu, mask, maskr, nw, ve, nve, ts, nts, lrate, nlrate, langevin, eps, doupdate, rstates);
  cudaDeviceSynchronize();
  if (langevin > 0)   cudaFree(rstates);
  cudaError_t err = cudaGetLastError();
  return err;
}

