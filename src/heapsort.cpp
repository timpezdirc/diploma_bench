#include <iostream>
#include <vector>
#include <chrono>
#include <random>
#include <algorithm>
#include <cstdlib>
#include <string>
#include <papi.h>

using namespace std;
using namespace std::chrono;


// PAPI error handling
void handle_papi_error(int retval, const string& message) {
    if(retval != PAPI_OK) {
        cerr << message << ": " << PAPI_strerror(retval) << endl;
        exit(1);
    }
}

// add named PAPI event
int add_named_event(int EventSet, const char* event_name) {
    int event_code = 0;

    int retval = PAPI_event_name_to_code(
        const_cast<char*>(event_name),
        &event_code
    );

    if(retval != PAPI_OK) {
        cerr << "Could not convert event name: " << event_name << " -> " << PAPI_strerror(retval) << endl;
        exit(1);
    }

    retval = PAPI_add_event(EventSet, event_code);

    if(retval != PAPI_OK) {
        cerr << "Could not add event: " << event_name << " -> " << PAPI_strerror(retval) << endl;
        exit(1);
    }

    cout << "[PAPI] Added: " << event_name << endl;

    return event_code;
}

// heapify function
void heapify(vector<int>& arr, int n, int i) {
    int largest = i;
    int left = 2 * i + 1;
    int right = 2 * i + 2;

    if(left < n && arr[left] > arr[largest]) {
        largest = left;
    }

    if(right < n && arr[right] > arr[largest]) {
        largest = right;
    }

    if(largest != i) {
        swap(arr[i], arr[largest]);
        heapify(arr, n, largest);
    }
}

// heapsort sorting function
void heapSort(vector<int>& arr) {
    int n = static_cast<int>(arr.size());

    for(int i = n / 2 - 1; i >= 0; i--) {
        heapify(arr, n, i);
    }

    for(int i = n - 1; i > 0; i--) {
        swap(arr[0], arr[i]);
        heapify(arr, i, 0);
    }
}

int main(int argc, char* argv[]) {
    int N = 10'000'000;
    int numRuns = 10;

    if(argc > 1) N = atoi(argv[1]);
    if(argc > 2) numRuns = atoi(argv[2]);

    // PAPI initialization
    int retval = PAPI_library_init(PAPI_VER_CURRENT);

    if(retval != PAPI_VER_CURRENT) {
        cerr << "PAPI library initialization failed!" << endl;
        return 1;
    }

    int EventSet = PAPI_NULL;

    handle_papi_error(
        PAPI_create_eventset(&EventSet),
        "PAPI_create_eventset failed"
    );

    // L1 data cache misses
    handle_papi_error(
        PAPI_add_event(EventSet, PAPI_L1_DCM),
        "Could not add PAPI_L1_DCM"
    );

    cout << "[PAPI] Added: PAPI_L1_DCM" << endl;

    // L2 data cache misses
    handle_papi_error(
        PAPI_add_event(EventSet, PAPI_L2_DCM),
        "Could not add PAPI_L2_DCM"
    );

    cout << "[PAPI] Added: PAPI_L2_DCM" << endl;

    // DRAM fills
    add_named_event(
        EventSet,
        "ANY_DATA_CACHE_FILLS_FROM_SYSTEM:DRAM_IO_NEAR:DRAM_IO_FAR"
    );

    cout << "[PAPI] Number of active events: " << PAPI_num_events(EventSet) << endl;

    // generate random input
    mt19937 rng(42);
    uniform_int_distribution<int> dist(0, 100'000'000);

    vector<int> original(N);

    for(int i = 0; i < N; i++) {
        original[i] = dist(rng);
    }

    // benchmarking
    double totalTime = 0.0;

    long long total_l1 = 0;
    long long total_l2 = 0;
    long long total_dram = 0;


    for(int run = 0; run < numRuns; run++) {

        // copy is OUTSIDE measurement
        vector<int> arr = original;
        long long values[3] = {0, 0, 0};

        // start PAPI counters
        handle_papi_error(
            PAPI_start(EventSet),
            "PAPI_start failed"
        );

        auto start = high_resolution_clock::now();

        heapSort(arr);

        auto end = high_resolution_clock::now();


        handle_papi_error(
            PAPI_stop(EventSet, values),
            "PAPI_stop failed"
        );

        double elapsed = duration<double>(end - start).count();
        totalTime += elapsed;

        // values[0] = PAPI_L1_DCM
        // values[1] = PAPI_L2_DCM
        // values[2] = DRAM fills
        total_l1 += values[0];
        total_l2 += values[1];
        total_dram += values[2];
    }

    // PAPI cleanup
    handle_papi_error(
        PAPI_cleanup_eventset(EventSet),
        "PAPI_cleanup_eventset failed"
    );

    handle_papi_error(
        PAPI_destroy_eventset(&EventSet),
        "PAPI_destroy_eventset failed"
    );

    // average results
    long long avg_l1 = total_l1 / numRuns;
    long long avg_l2 = total_l2 / numRuns;
    long long avg_dram_fills = total_dram / numRuns;


    cout << "N: " << N << "\n";

    cout << "Average time over " << numRuns << " runs: " << (totalTime / numRuns) << " seconds\n";

    cout << "Average L1 DCM: " << avg_l1 << "\n";

    cout << "Average L2 DCM: " << avg_l2 << "\n";

    cout << "Average DRAM FILLS: " << avg_dram_fills << "\n";

    return 0;
}