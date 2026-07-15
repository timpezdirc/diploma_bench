#include <iostream>
#include <vector>
#include <chrono>
#include <cmath>
#include <omp.h>

using namespace std;

// convert 2D grid coordinates to a 1D array index
inline size_t idx(size_t i, size_t j, size_t Ny) {
    return i * Ny + j;
}

// set fixed boundary values for the Laplace problem
void apply_boundary_conditions(vector<double> &u, size_t Nx, size_t Ny) {
    for(size_t i = 0; i < Nx; i++) {
        u[idx(i, 0, Ny)] = 1.0;            // bottom boundary
        u[idx(i, Ny - 1, Ny)] = 0.0;       // top boundary
    }

    for(size_t j = 0; j < Ny; j++) {
        u[idx(0, j, Ny)] = 0.0;            // left boundary
        u[idx(Nx - 1, j, Ny)] = 0.0;       // right boundary
    }
}

int main(int argc, char* argv[]) {
    size_t Nx = 2048;
    size_t Ny = 2048;
    size_t maxIter = 2000;
    size_t numRuns = 10;

    if(argc > 1) Nx = stoul(argv[1]);
    if(argc > 2) Ny = stoul(argv[2]);
    if(argc > 3) maxIter = stoul(argv[3]);
    if(argc > 4) numRuns = stoul(argv[4]);

    size_t totalSize = Nx * Ny;

    cout << "-------------------------------------------" << "\n";
    cout << "Grid: " << Nx << " x " << Ny << "\n";
    cout << "Total memory (2 arrays): "
         << (2.0 * totalSize * sizeof(double)) / (1024 * 1024) << " MB\n";
    cout << "Threads: " << omp_get_max_threads() << "\n";
    cout << "-------------------------------------------" << "\n";

    vector<double> u(totalSize, 0.0);
    vector<double> u_new(totalSize, 0.0);

    double totalTime = 0.0;
    double checksum  = 0.0;

    for(size_t run = 0; run < numRuns; run++) {
        fill(u.begin(), u.end(), 0.0);
        fill(u_new.begin(), u_new.end(), 0.0);

        apply_boundary_conditions(u, Nx, Ny);
        apply_boundary_conditions(u_new, Nx, Ny);

        auto start = chrono::high_resolution_clock::now();

        for(size_t iter = 0; iter < maxIter; iter++) {
            #pragma omp parallel for collapse(2)
            for(size_t i = 1; i < Nx - 1; i++) {
                for(size_t j = 1; j < Ny - 1; j++) {
                    size_t id = idx(i, j, Ny);
                    u_new[id] = 0.25 * (
                        u[id + Ny] + u[id - Ny] +
                        u[id + 1]  + u[id - 1]);
                }
            }

            swap(u, u_new); // swap current and updated grids
        }

        auto end = chrono::high_resolution_clock::now();
        totalTime += chrono::duration<double>(end - start).count();

        if(run == numRuns - 1) {
            for(size_t i = 0; i < totalSize; i++) {
                checksum += u[i];
            }
        }
    }

    cout << "-------------------------------------------" << "\n";
    cout << "Average time over " << numRuns << " runs: "
         << totalTime / numRuns << " seconds\n";
    cout << "Checksum: " << checksum << "\n";

    return 0;
}
