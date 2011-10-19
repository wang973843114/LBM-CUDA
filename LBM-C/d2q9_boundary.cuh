#ifndef D2Q9_BOUNDARY_H
#define D2Q9_BOUNDARY_H

__device__ inline Node zh_pressure_x(Node input, float rho_boundary);
__device__ inline Node zh_pressure_X(Node input, float rho_boundary);
__device__ inline Node zh_pressure_edge(Node input, float rho_boundary, int vector_order[8], int direction);

#endif