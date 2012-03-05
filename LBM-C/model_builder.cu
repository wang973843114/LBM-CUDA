#ifndef MODEL_BUILDER
#define MODEL_BUILDER

#include <stdio.h>
#include <string.h>
#include <iostream>
#include <sstream>
#include <vector>
#include "infile_reader.cu"
#include "cgns/cgns_input_handler.cu"
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "cuda_util.cu"
using namespace std;

#define STR_LENGTH 31

class ModelBuilder
{
	int length[DIM];
	// DEVICE VARIABLE DECLARATION
	OutputController *output_controller_d;
	Lattice *lattice_d;
	DomainArray *domain_arrays_d;
	DomainConstant *domain_constants_d;
	double **f_1_d, **f_2_d, *rho_d, **u_d, *boundary_value_d, *geometry_d, **force_d; 
	int *boundary_type_d;

	// HOST VARIABLE DECLARATION
	Timing *time_t;
	ProjectStrings *project_t;
	OutputController *output_controller_h;
	Lattice *lattice_h, *lattice_d_prototype;
	DomainArray *domain_arrays_h;
	DomainConstant *domain_constants_h;
	double **f_h, *rho_h, **u_h, *boundary_value_h, *geometry_h, **force_h;
	int *boundary_type_h;

	// SCALAR DECLARATION (PLATFORM AGNOSTIC)
	double tau, residual;
	double tolerance;
	int domain_size, maxT, saveT, steadyT, collision_type;

	// CONFIG FLAGS AND STRINGS
	char *fname_config;
	bool zhou_he;
	bool forcing;
	bool is2D;

// Allocates memory for variables which are constant in size
	void constant_size_allocator()
	{
		// Allocate container structures
		//combi_malloc<Lattice>(&lattice_h, &lattice_d, sizeof(Lattice));
		//combi_malloc<DomainArray>(&domain_arrays_h, &domain_arrays_d, sizeof(DomainArray));
		//combi_malloc<DomainConstant>(&domain_constants_h, &domain_constants_d, sizeof(DomainConstant));
		//combi_malloc<OutputController>(&output_controller_h, &output_controller_d, sizeof(OutputController));
		//domain_constants_h = (DomainConstant *)malloc(sizeof(DomainConstant));
		//time_t = (Timing *)malloc(sizeof(Timing));
		//project_t = (ProjectStrings *)malloc(sizeof(ProjectStrings));
	}

	void constant_loader()
	{
		InfileReader infile_reader(fname_config, project_t, domain_constants_h, time_t, output_controller_h);
		//transfer domain_constants to device (cant think of a better place to put this)
		cudasafe(cudaMemcpy(domain_constants_d, domain_constants_h, sizeof(DomainConstant),cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
		cudasafe(cudaMemcpy(output_controller_d, output_controller_h, sizeof(OutputController),cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
	}

// Allocates memory for variables which have variable size due to problem geometry
	void variable_size_allocator()
	{
		domain_size = 1;
		for(int d = 0; d<DIM; d++)
		{
			domain_size = domain_size*domain_constants_h->length[d];
		}
		int domain_data_size;
		domain_data_size = domain_size*sizeof(double);

		// Allocate required arrays
		// PDFS
		double *f_1_tmp[Q],*f_2_tmp[Q];
		combi_malloc<double*>(&f_h, &f_1_d, sizeof(double*)*Q);
		cudasafe(cudaMalloc((void **)&f_2_d,sizeof(double*)*Q), "Model Builder: Device memory allocation failed!");
		for(int i=0;i<Q;i++)
		{
			combi_malloc<double>(&f_h[i], &f_1_tmp[i], domain_data_size);
			cudasafe(cudaMalloc((void **)&f_2_tmp[i], domain_data_size), "Model Builder: Device memory allocation failed!");
		}
		cudasafe(cudaMemcpy(f_1_d,f_1_tmp,sizeof(double*)*Q,cudaMemcpyHostToDevice), "Model Builder: Device memory allocation failed!");
		cudasafe(cudaMemcpy(f_2_d,f_2_tmp,sizeof(double*)*Q,cudaMemcpyHostToDevice), "Model Builder: Device memory allocation failed!");
		
		// RHO
		combi_malloc<double>(&rho_h, &rho_d, domain_data_size);
		
		// VELOCITY
		double *u_tmp[DIM];
		combi_malloc<double*>(&u_h, &u_d, sizeof(double*)*DIM);
		for(int i=0;i<DIM;i++)
		{
			combi_malloc<double>(&u_h[i], &u_tmp[i], domain_data_size);
		}
		cudasafe(cudaMemcpy(u_d,u_tmp,sizeof(double*)*DIM, cudaMemcpyHostToDevice), "Model Builder: Device memory allocation failed!");

		// GEOMETRY
		combi_malloc<double>(&geometry_h, &geometry_d, domain_data_size);
		
		// ALLOCATE OPTION ARRAYS
		// FORCING
		if(domain_constants_h->forcing == true)
		{
			double *force_tmp[DIM];
			combi_malloc<double*>(&force_h, &force_d, sizeof(double*)*DIM);
			for(int i=0;i<DIM;i++)
			{
				combi_malloc<double>(&force_h[i], &force_tmp[i], domain_data_size);
			}
			cudasafe(cudaMemcpy(force_d,force_tmp,sizeof(double*)*DIM, cudaMemcpyHostToDevice), "Model Builder: Device memory allocation failed!");
		}

		// ZHOU/HE
		if(domain_constants_h->zhou_he == 1)
		{
			combi_malloc<int>(&boundary_type_h, &boundary_type_d, domain_data_size);
			combi_malloc<double>(&boundary_value_h, &boundary_value_d, domain_data_size);
		}
	}

	void variable_assembler()
	{
		lattice_h->f_prev = f_h;
		lattice_h->f_curr = f_h;
		lattice_h->u = u_h;
		lattice_h->rho = rho_h;

		Lattice *lattice_d_tmp = (Lattice *)malloc(sizeof(Lattice));
		lattice_d_tmp->f_prev = f_1_d;
		lattice_d_tmp->f_curr = f_2_d;
		lattice_d_tmp->u = u_d;
		lattice_d_tmp->rho = rho_d;
		cudasafe(cudaMemcpy(lattice_d, lattice_d_tmp, sizeof(Lattice),cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");

		domain_arrays_h->boundary_type = boundary_type_h;
		domain_arrays_h->boundary_value = boundary_value_h;
		domain_arrays_h->geometry = geometry_h;
		domain_arrays_h->force = force_h;

		DomainArray *domain_arrays_d_tmp = (DomainArray *)malloc(sizeof(DomainArray));
		domain_arrays_d_tmp->boundary_type = boundary_type_d;
		domain_arrays_d_tmp->boundary_value = boundary_value_d;
		domain_arrays_d_tmp->geometry = geometry_d;
		domain_arrays_d_tmp->force = force_d;
		cudasafe(cudaMemcpy(domain_arrays_d, domain_arrays_d_tmp, sizeof(DomainArray),cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
	}

	void variable_loader()
	{
		// LOAD GEOMETRY
		CGNSInputHandler input_handler(project_t->domain_fname, domain_constants_h->length);
		input_handler.read_field(domain_arrays_h->geometry, "Porosity");
		cudasafe(cudaMemcpy(geometry_d, geometry_h, sizeof(double)*domain_size,cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
		
		// LOAD FORCES IF REQUIRED
		if(domain_constants_h->forcing == true)
		{
			char force_labels[3][33];
			strcpy(force_labels[0], "ForceX");
			strcpy(force_labels[1], "ForceY");
			strcpy(force_labels[2], "ForceZ");

			double *force_d_tmp[DIM];

			cudasafe(cudaMemcpy(force_d_tmp, force_d, sizeof(double*)*Q,cudaMemcpyDeviceToHost),"Model Builder: Copy from device memory failed!");

			for(int d=0;d<DIM;d++)
			{
				input_handler.read_field(domain_arrays_h->force[d], force_labels[d]);
				cudasafe(cudaMemcpy(force_d_tmp[d], force_h[d], sizeof(double)*domain_size,cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
			}
		}

		// LOAD ZHOU/HE VARIABLES IF REQUIRED
		if(domain_constants_h->zhou_he == 1)
		{
			input_handler.read_field(domain_arrays_h->boundary_type, "BCType");
			cout << "blah blah" << domain_size << endl;
			//input_handler.read_field(boundary_type_h, "BCType");
			cudasafe(cudaMemcpy(boundary_type_d, boundary_type_h, sizeof(int)*domain_size,cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");

			input_handler.read_field(domain_arrays_h->boundary_value, "BCValue");
			cudasafe(cudaMemcpy(boundary_value_d, boundary_value_h, sizeof(double)*domain_size,cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
		}

		if(domain_constants_h->init_type == 0)
		{
			load_static_IC();
		}
	}

	void load_static_IC()
{
	double *f_1_d_tmp[Q];
	cudasafe(cudaMemcpy(f_1_d_tmp, f_1_d, sizeof(double*)*Q,cudaMemcpyDeviceToHost),"Model Builder: Copy from device memory failed!");

	double *f_2_d_tmp[Q];
	cudasafe(cudaMemcpy(f_2_d_tmp, f_2_d, sizeof(double*)*Q,cudaMemcpyDeviceToHost),"Model Builder: Copy from device memory failed!");

	double omega[Q];
	LOAD_OMEGA(omega);
	for(int i=0;i<Q;i++)
	{
		for(int index=0;index<(domain_size);index++)
		{
			lattice_h->f_curr[i][index] = 1.0*omega[i];
		}
		cudasafe(cudaMemcpy(f_1_d_tmp[i], f_h[i], sizeof(double)*domain_size,cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
		cudasafe(cudaMemcpy(f_2_d_tmp[i], f_h[i], sizeof(double)*domain_size,cudaMemcpyHostToDevice),"Model Builder: Copy to device memory failed!");
	}
}

public:
	ModelBuilder (char *, Lattice*, Lattice*, DomainConstant*, DomainConstant*, DomainArray*, DomainArray*, OutputController*, OutputController*, Timing*, ProjectStrings*);

	ModelBuilder ();

	void get_model(Lattice *lattice_host, Lattice *lattice_device, DomainConstant *domain_constants_host, DomainConstant *domain_constants_device, DomainArray *domain_arrays_host, DomainArray *domain_arrays_device, OutputController *output_controller_host, OutputController *output_controller_device, Timing *time, ProjectStrings *project)
	{
		lattice_host = lattice_h;
		lattice_device = lattice_d;
		domain_constants_host = domain_constants_h;
		domain_constants_device = domain_constants_d;
		domain_arrays_host = domain_arrays_h;
		domain_arrays_device = domain_arrays_d;
		output_controller_host = output_controller_h;
		output_controller_device = output_controller_d;
		time = time_t;
		project = project_t;
	}

};

ModelBuilder::ModelBuilder (char *input_filename, Lattice *lattice_host, Lattice *lattice_device, DomainConstant *domain_constants_host, DomainConstant *domain_constants_device, DomainArray *domain_arrays_host, DomainArray *domain_arrays_device, OutputController *output_controller_host, OutputController *output_controller_device, Timing *time, ProjectStrings *project) 
{
	lattice_h= lattice_host;
	lattice_d= lattice_device;
	domain_constants_h= domain_constants_host;
	domain_constants_d= domain_constants_device;
	domain_arrays_h= domain_arrays_host;
	domain_arrays_d= domain_arrays_device;
	output_controller_h= output_controller_host;
	output_controller_d = output_controller_device;
	time_t = time;
	project_t = project;

	fname_config = input_filename;
	constant_size_allocator();
	constant_loader();
	variable_size_allocator();
	variable_assembler();
	cout << "variable assembler complete" << endl;
	variable_loader();
	cout << "variable loader complete" << endl;
}

ModelBuilder::ModelBuilder (){}

#endif