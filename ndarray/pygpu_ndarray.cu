#include <Python.h>
#include <structmember.h>

#include <numpy/arrayobject.h>
#include <iostream>

#include "pygpu_ndarray.cuh"
#include "pygpu_language.h"

//#include "pygpu_ndarray_ctor.cu"//TODO correctly handle the compilation...


/////////////////////////
// Static helper methods
/////////////////////////

static void
PyGpuNdArray_null_init(PyGpuNdArrayObject *self)
{
    if(0) fprintf(stderr, "PyGpuNdArrayObject_null_init\n");

    PyGpuNdArray_DATA(self) = NULL;
    PyGpuNdArray_OFFSET(self) = 0;
    PyGpuNdArray_NDIM(self) = -1;
    self->base = NULL;
    PyGpuNdArray_DIMS(self) = NULL;
    PyGpuNdArray_STRIDES(self) = NULL;
    PyGpuNdArray_FLAGS(self) = NPY_DEFAULT;
    self->descr = NULL;

    self->data_allocated = 0;
}



/////////////////////////////
// Satisfying reqs to be Type
/////////////////////////////

//DON'T use directly(if their is other PyGpuNdArrayObject that point to it, it will cause problem)! use Py_DECREF() instead
static void
PyGpuNdArrayObject_dealloc(PyGpuNdArrayObject* self)
{
    if(0) fprintf(stderr, "PyGpuNdArrayObject_dealloc\n");
    if (0) std::cerr << "PyGpuNdArrayObject dealloc " << self << " "<<self->data_allocated<<'\n';
    if (0) std::cerr << "PyGpuNdArrayObject dealloc " << self << " " << PyGpuNdArray_DATA(self) << '\n';

    if(self->ob_refcnt>1)
      printf("WARNING:PyGpuNdArrayObject_dealloc called when their is still active reference to it.\n");

    if (self->data_allocated){
        assert(PyGpuNdArray_DATA(self));
        if (PyGpuNdArray_DATA(self)){
            if (device_free(PyGpuNdArray_DATA(self))){
	      fprintf(stderr,
		  "!!!! error freeing device memory %p (self=%p)\n",
		  PyGpuNdArray_DATA(self), self);
	    }
	    PyGpuNdArray_DATA(self) = NULL;
	}
    }
    PyGpuNdArray_OFFSET(self) = 0;
    PyGpuNdArray_NDIM(self) = -1;
    Py_XDECREF(self->base);
    self->base = NULL;
    if (PyGpuNdArray_DIMS(self)){
        free(PyGpuNdArray_DIMS(self));
        PyGpuNdArray_DIMS(self) = NULL;
    }
    if (PyGpuNdArray_STRIDES(self)){
        free(PyGpuNdArray_STRIDES(self));
        PyGpuNdArray_STRIDES(self) = NULL;
    }
    PyGpuNdArray_FLAGS(self) = NPY_DEFAULT;
    //Py_XDECREF(self->descr);//TODO: How to handle the refcont on this object?
    self->descr = NULL;
    self->data_allocated = 0;

    self->ob_type->tp_free((PyObject*)self);
    --_outstanding_mallocs[1];
    if(0){
        fprintf(stderr, "device_malloc_counts: (device) %i (obj) %i\n",
                _outstanding_mallocs[0],
                _outstanding_mallocs[1]);
    }
    if(0) fprintf(stderr, "PyGpuNdArrayObject_dealloc end\n");
}

static PyObject *
PyGpuNdArray_new(PyTypeObject *type, PyObject *args, PyObject *kwds)
{
    if(0) fprintf(stderr, "PyGpuNdArray_new\n");
    PyGpuNdArrayObject *self;

    self = (PyGpuNdArrayObject *)type->tp_alloc(type, 0);
    if (self != NULL){
        PyGpuNdArray_null_init(self);
        ++_outstanding_mallocs[1];
    }
    if(0) fprintf(stderr, "PyGpuNdArray_new end %p\n", self);
    return (PyObject *)self;
}

static int
PyGpuNdArray_init(PyGpuNdArrayObject *self, PyObject *args, PyObject *kwds)
{
    if(0) fprintf(stderr, "PyGpuNdArray_init\n");
    PyObject *arr=NULL;

    if (! PyArg_ParseTuple(args, "O", &arr))
        return -1;
    if (! PyArray_Check(arr)){
        PyErr_SetString(PyExc_TypeError, "PyGpuNdArrayObject_init: PyArray or PyGpuNdArrayObject arg required");
        return -1;
    }

    // TODO: We must create a new copy of the PyArray_Descr(or this only increment the refcount?) or still the reference?
    PyArray_Descr * type = PyArray_DescrFromType(PyArray_TYPE(arr));
    self->descr = type;
    Py_XINCREF(self->descr);//TODO: How to handle the refcont on this object?
    int rval = PyGpuNdArray_CopyFromArray(self, (PyArrayObject*)arr);
    if(0) fprintf(stderr, "PyGpuNdArray_init: end %p type=%p\n", self, self->descr);
    return rval;
}


int
PyGpuNdArray_CopyFromArray(PyGpuNdArrayObject * self, PyArrayObject*obj)
{
    if(0) fprintf(stderr, "PyGpuNdArray_CopyFromArray: start descr=%p\n", self->descr);
    //modif done to the new array won't be updated!
    assert(!PyArray_CHKFLAGS(self, NPY_UPDATEIFCOPY));
    //Aligned are not tested, so don't allow it for now
    assert(!PyArray_CHKFLAGS(self, NPY_ALIGNED));

    int typenum = PyArray_TYPE(obj);
    PyObject * py_src = NULL;
    if (PyArray_ISONESEGMENT(obj)) {
        Py_INCREF(obj);
        py_src = (PyObject *) obj;
    }else{
        py_src = PyArray_ContiguousFromAny((PyObject*)obj, typenum, PyArray_NDIM(obj), PyArray_NDIM(obj));
    }
    if(0) fprintf(stderr, "PyGpuNdArray_CopyFromArray: contiguous!\n");
    if (!py_src) {
        return -1;
    }

    int err;
    if(PyArray_ISFORTRAN(obj) && ! PyArray_ISCONTIGUOUS(obj)){
      err = PyGpuNdArray_alloc_contiguous(self, obj->nd, obj->dimensions, NPY_FORTRANORDER);
    }else{
      err = PyGpuNdArray_alloc_contiguous(self, obj->nd, obj->dimensions);
    }
    if (err) {
        return err;
    }

    //check that the flag are the same
    if (PyArray_ISCONTIGUOUS(py_src) != PyGpuNdArray_ISCONTIGUOUS(self) &&
        PyArray_ISFORTRAN(obj) && 0) {
        PyErr_Format(PyExc_RuntimeError, "ISCONTIGUOUS %d %d\n", PyArray_ISCONTIGUOUS(py_src), PyGpuNdArray_ISCONTIGUOUS(self));
        return -1;
    }
    assert(PyArray_ISCONTIGUOUS(py_src) == PyGpuNdArray_ISCONTIGUOUS(self) ||
           PyArray_ISFORTRAN(obj));
    assert(PyArray_ISFORTRAN(py_src) == PyGpuNdArray_ISFORTRAN(self));
    assert(PyArray_ISALIGNED(py_src) == PyGpuNdArray_ISALIGNED(self));

    // New memory, so we should own it.
    assert(PyGpuNdArray_CHKFLAGS(self, NPY_OWNDATA));
    // New memory, so it should be writable
    assert(PyGpuNdArray_ISWRITEABLE(self));


    cublasSetVector(PyArray_SIZE(py_src),
		    PyArray_ITEMSIZE(py_src),
		    PyArray_DATA(py_src), 1,
		    PyGpuNdArray_DATA(self), 1);
    CNDA_THREAD_SYNC;
    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "error copying data to device memory");
        Py_DECREF(py_src);
        return -1;
    }
    Py_DECREF(py_src);
    return 0;
}

//updated for offset
PyObject * PyGpuNdArray_CreateArrayObj(PyGpuNdArrayObject * self)
{
    int verbose = 0;

    if(verbose) fprintf(stderr, "PyGpuNdArray_CreateArrayObj\n");

    assert(PyGpuNdArray_OFFSET(self)==0);//TODO implement when offset is not 0!

    if(PyGpuNdArray_NDIM(self)>=0 && PyGpuNdArray_SIZE(self)==0){
      npy_intp * npydims = (npy_intp*)malloc(PyGpuNdArray_NDIM(self) * sizeof(npy_intp));
      assert (npydims);
      for (int i = 0; i < PyGpuNdArray_NDIM(self); ++i)
	npydims[i] = (npy_intp)(PyGpuNdArray_DIMS(self)[i]);
      //TODO: refcount on descr!
      PyObject * rval = PyArray_Empty(PyGpuNdArray_NDIM(self),
				      npydims, self->descr,
				      PyGpuNdArray_ISFARRAY(self));
      free(npydims);
      if (!rval){
        return NULL;
      }
      assert (PyArray_ITEMSIZE(rval) == PyGpuNdArray_ITEMSIZE(self));
      return rval;
    }
    if ((PyGpuNdArray_NDIM(self) < 0) || (PyGpuNdArray_DATA(self) == 0))
    {
        PyErr_SetString(PyExc_ValueError, "can't copy from un-initialized PyGpuNdArray");
        return NULL;
    }
    PyGpuNdArrayObject * contiguous_self = NULL;
    if (PyGpuNdArray_ISONESEGMENT(self))
    {
        contiguous_self = self;
        Py_INCREF(contiguous_self);
        if (verbose) std::cerr << "PyGpuNdArray_CreateArrayObj:gpu array already contiguous" <<
		       contiguous_self << '\n';
    }
    else
    {
        //TODO implement PyGpuNdArray_Copy
        //contiguous_self = (PyGpuNdArrayObject*)PyGpuNdArray_Copy(self);
        //  if (verbose) std::cerr << "CreateArrayObj created contiguous" << contiguous_self << '\n';
        PyErr_SetString(PyExc_ValueError, "PyGpuNdArray_CreateArrayObj: Need PyGpuNdArray_Copy to be implemented to be able to transfer not contiguous memory block.");
        return NULL;

    }
    if (!contiguous_self)
    {
        return NULL;
    }

    npy_intp * npydims = (npy_intp*)malloc(PyGpuNdArray_NDIM(self) * sizeof(npy_intp));
    assert (npydims);
    for (int i = 0; i < PyGpuNdArray_NDIM(self); ++i) npydims[i] = (npy_intp)(PyGpuNdArray_DIMS(self)[i]);
    PyObject * rval = PyArray_Empty(PyGpuNdArray_NDIM(self),
				    npydims,
				    PyGpuNdArray_DESCR(self),
				    PyGpuNdArray_ISFORTRAN(self));
    free(npydims);
    if (!rval)
    {
        Py_DECREF(contiguous_self);
        return NULL;
    }

    cublasGetVector(PyArray_SIZE(rval), PyArray_ITEMSIZE(rval),
		    PyGpuNdArray_DATA(contiguous_self), 1,
		    PyArray_DATA(rval), 1);
    CNDA_THREAD_SYNC;

    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "error copying data to host");
        Py_DECREF(rval);
        rval = NULL;
    }

    Py_DECREF(contiguous_self);
    return rval;
}

static PyMethodDef PyGpuNdArray_methods[] =
{
    {"__array__",
        (PyCFunction)PyGpuNdArray_CreateArrayObj, METH_NOARGS,
        "Copy from the device to a numpy ndarray"},
    /*    {"__copy__",
        (PyCFunction)PyGpuNdArray_View, METH_NOARGS,
        "Create a shallow copy of this object. used by module copy"},
    {"__deepcopy__",
        (PyCFunction)PyGpuNdArray_DeepCopy, METH_O,
        "Create a copy of this object"},
    {"zeros",
        (PyCFunction)PyGpuNdArray_Zeros, METH_STATIC,
        "Create a new PyGpuNdArray with specified shape, filled with zeros."},
    {"copy",
        (PyCFunction)PyGpuNdArray_Copy, METH_NOARGS,
        "Create a copy of this object"},
    {"reduce_sum",
        (PyCFunction)PyGpuNdArray_ReduceSum, METH_O,
        "Reduce over the given dimensions by summation"},
    {"exp",
        (PyCFunction)PyGpuNdArray_Exp, METH_NOARGS,
        "Return the exponential of all elements"},
    {"reshape",
        (PyCFunction)PyGpuNdArray_Reshape, METH_O,
        "Return a reshaped view (or copy) of this ndarray\n\
            The required argument is a tuple of integers specifying the shape of the new ndarray."},
    {"view",
        (PyCFunction)PyGpuNdArray_View, METH_NOARGS,
        "Return an alias of this ndarray"},
    {"_set_stride",
        (PyCFunction)PyGpuNdArray_SetStride, METH_VARARGS,
        "For integer arguments (i, s), set the 'i'th stride to 's'"},
    {"_set_shape_i",
        (PyCFunction)PyGpuNdArray_SetShapeI, METH_VARARGS,
        "For integer arguments (i, s), set the 'i'th shape to 's'"},
    */
    {NULL, NULL, NULL, NULL}  /* Sentinel */
};

//PyArray_CopyInto(PyArrayObject* dest, PyArrayObject* src)¶
//PyObject* PyArray_NewCopy(PyArrayObject* old, NPY_ORDER order)¶


static PyObject *
PyGpuNdArray_get_shape(PyGpuNdArrayObject *self, void *closure)
{
    if(0) fprintf(stderr, "PyGpuNdArray_get_shape\n");

    if (PyGpuNdArray_NDIM(self) < 0)
    {
        PyErr_SetString(PyExc_ValueError, "PyGpuNdArray not initialized");
        return NULL;
    }
    PyObject * rval = PyTuple_New(PyGpuNdArray_NDIM(self));
    for (int i = 0; i < PyGpuNdArray_NDIM(self); ++i)
    {
        if (!rval || PyTuple_SetItem(rval, i, PyInt_FromLong(PyGpuNdArray_DIMS(self)[i])))
        {
            Py_XDECREF(rval);
            return NULL;
        }

    }
    return rval;
}

static int
PyGpuNdArray_set_shape(PyGpuNdArrayObject *self, PyObject *value, void *closure)
{
    PyErr_SetString(PyExc_NotImplementedError, "TODO: call reshape");
    return -1;
}

static PyObject *
PyGpuNdArray_get_strides(PyGpuNdArrayObject *self, void *closure)
{
  if ( PyGpuNdArray_NDIM(self) < 0){
      PyErr_SetString(PyExc_ValueError, "PyGpuNdArrayObject not initialized");
      return NULL;
    }
  PyObject * rval = PyTuple_New( PyGpuNdArray_NDIM(self));
  for (int i = 0; i < PyGpuNdArray_NDIM(self); ++i){
      if (!rval || PyTuple_SetItem(rval, i, PyInt_FromLong(PyGpuNdArray_STRIDES(self)[i]))){
	  Py_XDECREF(rval);
	  return NULL;
        }
    }
  return rval;
}

static PyObject *
PyGpuNdArray_get_data(PyGpuNdArrayObject *self, void *closure)
{
    return PyInt_FromLong((long int) PyGpuNdArray_DATA(self));
}

static PyObject *
PyGpuNdArray_get_flags(PyGpuNdArrayObject *self, void *closure)
{
    return PyInt_FromLong((long int) PyGpuNdArray_FLAGS(self));
}
static PyObject *
PyGpuNdArray_get_ndim(PyGpuNdArrayObject *self, void *closure)
{
    return PyInt_FromLong((long int) PyGpuNdArray_NDIM(self));
}
static PyObject *
PyGpuNdArray_get_offset(PyGpuNdArrayObject *self, void *closure)
{
    return PyInt_FromLong((long int) PyGpuNdArray_OFFSET(self));
}
static PyObject *
PyGpuNdArray_get_data_allocated(PyGpuNdArrayObject *self, void *closure)
{
    return PyInt_FromLong((long int) self->data_allocated);
}
static PyObject *
PyGpuNdArray_get_size(PyGpuNdArrayObject *self, void *closure)
{
    return PyInt_FromLong((long int) PyGpuNdArray_SIZE(self));
}

static PyObject *
PyGpuNdArray_get_base(PyGpuNdArrayObject *self, void *closure)
{
    if (!PyGpuNdArray_BASE(self)){
        Py_INCREF(Py_None);
        return Py_None;
    }
    return PyGpuNdArray_BASE(self);
}

static PyObject *
PyGpuNdArray_get_dtype(PyArrayObject *self)
{
    Py_INCREF(PyGpuNdArray_DESCR(self));
    PyObject * ret = (PyObject *)PyGpuNdArray_DESCR(self);
    return ret;
}

static PyObject *
PyGpuNdArray_get_itemsize(PyArrayObject *self)
{
    return (PyObject *)PyGpuNdArray_ITEMSIZE(self);
}

static PyGetSetDef PyGpuNdArray_getset[] = {
    {"base",
        (getter)PyGpuNdArray_get_base,
        NULL,
        "Return the object stored in the base attribute",
        NULL},
    {"bytes",
        (getter)PyGpuNdArray_get_data,
        NULL,
        "device data pointer",
        NULL},
    {"shape",
        (getter)PyGpuNdArray_get_shape,
        (setter)PyGpuNdArray_set_shape,
        "shape of this ndarray (tuple)",
        NULL},
    {"strides",
        (getter)PyGpuNdArray_get_strides,
        NULL,//(setter)PyGpuNdArray_set_strides,
        "data pointer strides (in elements)",
        NULL},
    {"ndim",
        (getter)PyGpuNdArray_get_ndim,
        NULL,
        "The number of dimensions in this object",
        NULL},
    {"offset",
        (getter)PyGpuNdArray_get_offset,
        NULL,
        "Return the offset value",
        NULL},
    {"size",
        (getter)PyGpuNdArray_get_size,
        NULL,
        "The number of elements in this object.",
        NULL},
    {"data_allocated",
        (getter)PyGpuNdArray_get_data_allocated,
        NULL,
        "The size of the allocated memory on the device.",
        NULL},
    {"itemsize",
        (getter)PyGpuNdArray_get_itemsize,
        NULL,
        "The size of the base element.",
        NULL},
    {"dtype",
	(getter)PyGpuNdArray_get_dtype,
	NULL,
	"The dtype of the element",
	NULL},
     /*
    {"_flags",
        (getter)PyGpuNdArray_get_flags,
        NULL,
        "Return the flags as an int",
        NULL},
    */
    {NULL, NULL, NULL, NULL}  /* Sentinel */
};
static PyTypeObject PyGpuNdArrayType =
{
    PyObject_HEAD_INIT(NULL)
    0,                         /*ob_size*/
    "GpuNdArray",             /*tp_name*/
    sizeof(PyGpuNdArrayObject),       /*tp_basicsize*/
    0,                         /*tp_itemsize*/
    (destructor)PyGpuNdArrayObject_dealloc, /*tp_dealloc*/
    0,                         /*tp_print*/
    0,                         /*tp_getattr*/
    0,                         /*tp_setattr*/
    0,                         /*tp_compare*/
    0,                         /*tp_repr*/
    0, //&PyGpuNdArrayObjectNumberMethods, /*tp_as_number*/
    0,                         /*tp_as_sequence*/
    0, //&PyGpuNdArrayObjectMappingMethods,/*tp_as_mapping*/
    0,                         /*tp_hash */
    0,                         /*tp_call*/
    0,                         /*tp_str*/
    0,                         /*tp_getattro*/
    0,                         /*tp_setattro*/
    0,                         /*tp_as_buffer*/
    Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE | Py_TPFLAGS_CHECKTYPES, /*tp_flags*/
    "PyGpuNdArrayObject objects",     /* tp_doc */
    0,                         /* tp_traverse */
    0,                         /* tp_clear */
    0,                         /* tp_richcompare */
    0,                         /* tp_weaklistoffset */
    0,                         /* tp_iter */
    0,                         /* tp_iternext */
    PyGpuNdArray_methods,       /* tp_methods */
    0, //PyGpuNdArray_members,       /* tp_members */ //TODO
    PyGpuNdArray_getset,        /* tp_getset */
    0,                         /* tp_base */
    0,                         /* tp_dict */
    0,                         /* tp_descr_get */
    0,                         /* tp_descr_set */
    0,                         /* tp_dictoffset */
    (initproc)PyGpuNdArray_init,/* tp_init */
    0,                         /* tp_alloc */
    PyGpuNdArray_new,           /* tp_new */
};

//////////////////////////////////////
//
// C API FOR PyGpuNdArrayObject
//
//////////////////////////////////////
PyObject *
PyGpuNdArray_New(int nd)
{
    PyGpuNdArrayObject *self = (PyGpuNdArrayObject *)PyGpuNdArrayType.tp_alloc(&PyGpuNdArrayType, 0);
    if (self == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "PyGpuNdArray_New failed to allocate self");
        return NULL;
    }
    PyGpuNdArray_null_init(self);

    if (nd == 0) {
        PyGpuNdArray_NDIM(self) = 0;
    }
    else if (nd > 0) {
        if (PyGpuNdArray_set_nd(self, nd)) {
            Py_DECREF(self);
            return NULL;
        }
    }
    ++_outstanding_mallocs[1];
    return (PyObject *)self;
}

int
PyGpuNdArray_Check(const PyObject * ob)
{
    if(0) fprintf(stderr, "PyGpuNdArray_Check\n");
    //TODO: doesn't work with inheritance
    return PyGpuNdArray_CheckExact(ob);
}
int
PyGpuNdArray_CheckExact(const PyObject * ob)
{
    if(0) fprintf(stderr, "PyGpuNdArray_CheckExact\n");
    return ((ob->ob_type == &PyGpuNdArrayType) ? 1 : 0);
}


static PyMethodDef module_methods[] = {
    //{"dimshuffle", PyGpuNdArray_Dimshuffle, METH_VARARGS, "Returns the dimshuffle of a PyGpuNdArray."},
    {"outstanding_mallocs", outstanding_mallocs, METH_VARARGS, "how many more mallocs have been called than free's"},
    {NULL, NULL, NULL, NULL}  /* Sentinel */
};

#ifndef PyMODINIT_FUNC  /* declarations for DLL import/export */
#define PyMODINIT_FUNC void
#endif
PyMODINIT_FUNC
initpygpu_ndarray(void)
{
    import_array();

    PyObject* m;

    if (PyType_Ready(&PyGpuNdArrayType) < 0)
        return;

    m = Py_InitModule3("pygpu_ndarray", module_methods,
                       "Example module that creates an extension type.");

    if (m == NULL)
        return;

    Py_INCREF(&PyGpuNdArrayType);
    PyModule_AddObject(m, "GpuNdArrayObject", (PyObject *)&PyGpuNdArrayType);
#if COMPUTE_GPU_MEM_USED
    for(int i=0;i<TABLE_SIZE;i++){
      _alloc_size_table[i].ptr=NULL;
      _alloc_size_table[i].size=0;
    }
#endif
    //    cublasInit();
    //if (0&&CUBLAS_STATUS_SUCCESS != cublasGetError())
    //{
        //std::cerr << "WARNING: initcuda_ndarray: error initializing device\n";
    //}
/*
    if (0) //TODO: is this necessary?
    {
        int deviceId = 0; // TODO: what number goes here?
        cudaSetDevice(deviceId);
        cudaError_t err = cudaGetLastError();
        if( cudaSuccess != err)
        {
            std::cerr << "Error in SetDevice:" << cudaGetErrorString(err) << "\n";
        }
    }
*/
}

/*
  Local Variables:
  mode:c++
  c-basic-offset:4
  c-file-style:"stroustrup"
  c-file-offsets:((innamespace . 0)(inline-open . 0))
  indent-tabs-mode:nil
  fill-column:79
  End:
*/
// vim: filetype=cpp:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:encoding=utf-8:textwidth=79 :