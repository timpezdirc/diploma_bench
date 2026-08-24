#include <iostream>
#include <chrono>
#include <cmath>
#include <algorithm>
#include <fstream>
#include <string>
#include <cstdlib>
#include <memory>
#include <omp.h>
#include <sched.h>

using namespace std;

// perf stat helper class
class PerfController {
private:
    ofstream control;
    ifstream ack;
    bool enabled = false;

    void sendCommand(const string& command) {
        if(!enabled) {
            return;
        }

        control << command << '\n' << flush;

        if(!control) {
            cerr << "Failed to send perf control command: "
                 << command << '\n';
            exit(1);
        }

        string response;

        if(!getline(ack, response)) {
            cerr << "Failed to read acknowledgement from perf\n";
            exit(1);
        }

        if(response.find("ack") == string::npos) {
            cerr << "Unexpected perf acknowledgement: "
                 << response << '\n';
            exit(1);
        }
    }

public:
    PerfController() {
        const char* controlPath = getenv("PERF_CTL_FIFO");
        const char* ackPath = getenv("PERF_ACK_FIFO");

        if(controlPath == nullptr || ackPath == nullptr) {
            return;
        }

        control.open(controlPath);
        ack.open(ackPath);

        if(!control.is_open() || !ack.is_open()) {
            cerr << "Failed to open perf control FIFOs\n";
            exit(1);
        }

        enabled = true;
    }

    void startMeasurement() {
        sendCommand("enable");
    }

    void stopMeasurement() {
        sendCommand("disable");
    }
};

// Laplace helper functions
inline size_t idx(size_t i, size_t j, size_t Ny) {
    return i * Ny + j;
}

// apply boundary conditions to the 2D grid
void apply_boundary_conditions(double* u, size_t Nx, size_t Ny) {
    for(size_t i = 0; i < Nx; i++) {
        u[idx(i, 0, Ny)] = 1.0;
        u[idx(i, Ny - 1, Ny)] = 0.0;
    }

    for(size_t j = 0; j < Ny; j++) {
        u[idx(0, j, Ny)] = 0.0;
        u[idx(Nx - 1, j, Ny)] = 0.0;
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

    const size_t totalSize = Nx * Ny;

    cout << "-------------------------------------------" << "\n";
    cout << "Grid: " << Nx << " x " << Ny << "\n";
    cout << "Total memory (2 arrays): "
         << (2.0 * totalSize * sizeof(double)) / (1024 * 1024) << " MB\n";
    cout << "Threads: " << omp_get_max_threads() << "\n";
    cout << "-------------------------------------------" << "\n";

    // allocate memory WITHOUT initialization
    unique_ptr<double[]> u(new double[totalSize]);
    unique_ptr<double[]> u_new(new double[totalSize]);

    PerfController perf;

    double totalTime = 0.0;
    double checksum = 0.0;

    // diagnostic OpenMP thread placement
    cout << "===== OpenMP thread placement =====\n";

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        int cpu = sched_getcpu();

        #pragma omp critical
        {
            cout << "Thread " << tid << " -> CPU " << cpu << "\n";
        }
    }

    cout << "===================================\n";

    // benchmarking
    for(size_t run = 0; run < numRuns; run++) {
        chrono::high_resolution_clock::time_point start;
        chrono::high_resolution_clock::time_point end;

        // ----------------------------------------------------
        // Persistent OpenMP region.
        //
        // The SAME OpenMP team:
        //
        // 1. initializes the arrays in parallel (first-touch),
        // 2. starts perf counters,
        // 3. performs the measured Laplace kernel.
        //
        // Parallel initialization is outside perf counters
        // and outside the execution timer.
        // ----------------------------------------------------

        #pragma omp parallel shared( \
            u, u_new, \
            start, end, perf)
        {

            // parallel initialization / NUMA first-touch
            #pragma omp for collapse(2) schedule(static)
            for(size_t i = 0; i < Nx; i++) {
                for(size_t j = 0; j < Ny; j++) {
                    size_t id = idx(i, j, Ny);
                    u[id] = 0.0;
                    u_new[id] = 0.0;
                }
            }

            #pragma omp single
            {
                apply_boundary_conditions(
                    u.get(),
                    Nx,
                    Ny
                );

                apply_boundary_conditions(
                    u_new.get(),
                    Nx,
                    Ny
                );
            }

            // wait until all threads are completely ready
            #pragma omp barrier

            // start hardware counters
            #pragma omp single
            {
                perf.startMeasurement();
            }

            #pragma omp barrier

            // start timer only after counters are active
            #pragma omp single
            {
                start = chrono::high_resolution_clock::now();
            }

            // Laplace with Jacobi iteration
            for(size_t iter = 0; iter < maxIter; iter++) {
                #pragma omp for collapse(2) schedule(static)
                for(size_t i = 1; i < Nx - 1; i++) {
                    for(size_t j = 1; j < Ny - 1; j++) {
                        size_t id = idx(i, j, Ny);

                        u_new[id] = 0.25 * (u[id + Ny] + u[id - Ny] +
                                          u[id + 1] + u[id - 1]);
                    }
                }

                // omp single has an implicit barrier,
                // so no thread starts the next iteration
                // before the arrays have been swapped
                #pragma omp single
                {
                    swap(u, u_new);
                }
            }

            // stop timer
            #pragma omp single
            {
                end = chrono::high_resolution_clock::now();
            }

            #pragma omp barrier

            // stop hardware counters
            #pragma omp single
            {
                perf.stopMeasurement();
            }
        }

        // store result
        totalTime += chrono::duration<double>(end - start).count();
    }

    // checksum computation for validation
    for(size_t i = 0; i < totalSize; i++) {
        checksum += u[i];
    }

    // average results
    cout << "Average time over " << numRuns << " runs: "
         << totalTime / numRuns << " seconds\n";

    cout << "Checksum: " << checksum << "\n";

    return 0;
}