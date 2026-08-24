#include <iostream>
#include <chrono>
#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <string>
#include <memory>
#include <omp.h>
#include <papi.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sched.h>

using namespace std;

// PAPI helper functions
unsigned long papi_thread_id() {
    return static_cast<unsigned long>(syscall(SYS_gettid));
}


void handle_papi_error(int retval, const string& message) {
    if(retval != PAPI_OK) {
        cerr << message << ": " << PAPI_strerror(retval) << endl;
        abort();
    }
}


int get_named_event(const char* event_name) {
    int event_code = 0;

    int retval = PAPI_event_name_to_code(
        const_cast<char*>(event_name),
        &event_code
    );

    handle_papi_error(
        retval,
        string("Could not find event ") + event_name
    );

    return event_code;
}

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
    size_t numRuns = 1;

    if(argc > 1) Nx = stoul(argv[1]);
    if(argc > 2) Ny = stoul(argv[2]);
    if(argc > 3) maxIter = stoul(argv[3]);
    if(argc > 4) numRuns = stoul(argv[4]);

    const size_t totalSize = Nx * Ny;

    // PAPI initialization
    int retval = PAPI_library_init(PAPI_VER_CURRENT);

    if(retval != PAPI_VER_CURRENT) {
        cerr << "PAPI initialization failed" << endl;
        return 1;
    }

    handle_papi_error(
        PAPI_thread_init(papi_thread_id),
        "PAPI_thread_init failed"
    );

    // hardware events
    int dram_code = get_named_event(
        "ANY_DATA_CACHE_FILLS_FROM_SYSTEM:DRAM_IO_NEAR:DRAM_IO_FAR"
    );

    const int event_codes[3] = {
        PAPI_L1_DCM,
        PAPI_L2_DCM,
        dram_code
    };

    cout << "-------------------------------------------" << "\n";
    cout << "Grid: " << Nx << " x " << Ny << "\n";
    cout << "Total memory (2 arrays): "
         << (2.0 * totalSize * sizeof(double)) / (1024 * 1024) << " MB\n";
    cout << "Threads: " << omp_get_max_threads() << "\n";
    cout << "-------------------------------------------" << "\n";

    // allocate memory WITHOUT initialization
    unique_ptr<double[]> u(new double[totalSize]);
    unique_ptr<double[]> u_new(new double[totalSize]);

    double totalTime = 0.0;
    long long total_l1 = 0;
    long long total_l2 = 0;
    long long total_dram = 0;
    double checksum = 0.0;

    // benchmarking
    for(size_t run = 0; run < numRuns; run++) {
        long long run_l1 = 0;
        long long run_l2 = 0;
        long long run_dram = 0;

        chrono::high_resolution_clock::time_point start;
        chrono::high_resolution_clock::time_point end;

        // ----------------------------------------------------
        // Persistent OpenMP region.
        //
        // The SAME OpenMP team:
        //
        // 1. initializes the arrays in parallel (first-touch),
        // 2. initializes PAPI per thread,
        // 3. performs the measured Laplace kernel.
        //
        // Parallel initialization is outside PAPI counters
        // and outside the execution timer.
        // ----------------------------------------------------

        #pragma omp parallel shared( \
            u, u_new, \
            start, end, \
            run_l1, run_l2, \
            run_dram)
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

            // register OpenMP thread with PAPI
            handle_papi_error(
                PAPI_register_thread(),
                "PAPI_register_thread failed"
            );

            // one EventSet per thread, since PAPI is not thread-safe
            int EventSet = PAPI_NULL;

            handle_papi_error(
                PAPI_create_eventset(&EventSet),
                "PAPI_create_eventset failed"
            );

            // add three events
            for(int e = 0; e < 3; e++) {
                handle_papi_error(
                    PAPI_add_event(
                        EventSet,
                        event_codes[e]
                    ),
                    "PAPI_add_event failed"
                );
            }

            long long values[3] = {
                0,
                0,
                0
            };

            // wait until all threads are completely ready
            #pragma omp barrier

            // start counters
            handle_papi_error(
                PAPI_start(EventSet),
                "PAPI_start failed"
            );

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
            handle_papi_error(
                PAPI_stop(
                    EventSet,
                    values
                ),
                "PAPI_stop failed"
            );

            // sum counters over all threads
            #pragma omp critical
            {
                run_l1 += values[0];
                run_l2 += values[1];
                run_dram += values[2];
            }

            // cleanup PAPI
            handle_papi_error(
                PAPI_cleanup_eventset(EventSet),
                "PAPI_cleanup_eventset failed"
            );

            handle_papi_error(
                PAPI_destroy_eventset(&EventSet),
                "PAPI_destroy_eventset failed"
            );

            handle_papi_error(
                PAPI_unregister_thread(),
                "PAPI_unregister_thread failed"
            );
        }

        // store results
        totalTime += chrono::duration<double>(end - start).count();

        total_l1 += run_l1;
        total_l2 += run_l2;

        total_dram += run_dram;
    }

    // checksum computation for validation
    for(size_t i = 0; i < totalSize; i++) {
        checksum += u[i];
    }

    // average results
    long long avg_l1 = total_l1 / static_cast<long long>(numRuns);
    long long avg_l2 = total_l2 / static_cast<long long>(numRuns);
    long long avg_dram_fills = total_dram / static_cast<long long>(numRuns);

    cout << "Average time over " << numRuns << " runs: " << totalTime / numRuns << " seconds\n";

    cout << "Average L1 DCM: " << avg_l1 << "\n";

    cout << "Average L2 DCM: " << avg_l2 << "\n";

    cout << "Average DRAM FILLS: " << avg_dram_fills << "\n";

    cout << "Checksum: " << checksum << "\n";

    PAPI_shutdown();

    return 0;
}