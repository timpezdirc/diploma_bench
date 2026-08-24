#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <cmath>
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

void add_named_event(int EventSet, const char* event_name) {
    int event_code = 0;

    int retval = PAPI_event_name_to_code(
        const_cast<char*>(event_name),
        &event_code
    );

    if(retval != PAPI_OK) {
        cerr << "Could not convert event name: "
             << event_name
             << " -> "
             << PAPI_strerror(retval)
             << endl;
        exit(1);
    }

    retval = PAPI_add_event(EventSet, event_code);

    if(retval != PAPI_OK) {
        cerr << "Could not add event: "
             << event_name
             << " -> "
             << PAPI_strerror(retval)
             << endl;
        exit(1);
    }

    cout << "[PAPI] Added: " << event_name << endl;
}

// directed graph representation using adjacency lists
class Graph {
public:
    int N;
    vector<vector<int>> adjList;
    vector<int> outDegree;

    Graph(int n) : N(n), adjList(n), outDegree(n, 0) {}

    void addEdge(int u, int v) {
        adjList[u].push_back(v);
        outDegree[u]++;
    }
};

int main(int argc, char* argv[]) {
    int N = 3'000'000;
    int edgesPerNode = 16;
    int iterations = 20;

    if(argc > 1) N = atoi(argv[1]);
    if(argc > 2) edgesPerNode = atoi(argv[2]);
    if(argc > 3) iterations = atoi(argv[3]);

    Graph g(N);

    mt19937 rng(42);
    uniform_int_distribution<int> dist(0, N - 1);

    // build a random graph with a fixed out-degree per node
    for(int u = 0; u < N; u++) {
        for(int e = 0; e < edgesPerNode; e++) {
            int v = dist(rng);
            g.addEdge(u, v);
        }
    }

    vector<double> pr(N, 1.0 / N);
    vector<double> new_pr(N, 0.0);

    const double d = 0.85; // damping factor

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

    // L1
    handle_papi_error(
        PAPI_add_event(EventSet, PAPI_L1_DCM),
        "Could not add PAPI_L1_DCM"
    );

    cout << "[PAPI] Added: PAPI_L1_DCM" << endl;


    // L2
    handle_papi_error(
        PAPI_add_event(EventSet, PAPI_L2_DCM),
        "Could not add PAPI_L2_DCM"
    );

    cout << "[PAPI] Added: PAPI_L2_DCM" << endl;


    // DRAM near
    add_named_event(
        EventSet,
        "DEMAND_DATA_CACHE_FILLS_FROM_SYSTEM:DRAM_IO_NEAR"
    );


    // DRAM far
    add_named_event(
        EventSet,
        "DEMAND_DATA_CACHE_FILLS_FROM_SYSTEM:DRAM_IO_FAR"
    );


    cout << "[PAPI] Number of active events: "
         << PAPI_num_events(EventSet)
         << endl;

    long long values[4] = {0, 0, 0, 0};

    handle_papi_error(
        PAPI_start(EventSet),
        "PAPI_start failed"
    );

    auto start = high_resolution_clock::now();

    for(int iter = 0; iter < iterations; iter++) {
        fill(new_pr.begin(), new_pr.end(), (1.0 - d) / N);

        for(int u = 0; u < N; u++) {
            if(g.outDegree[u] == 0) continue;

            double contribution = d * pr[u] / g.outDegree[u];

            for(int v : g.adjList[u]) {
                new_pr[v] += contribution;
            }
        }

        pr.swap(new_pr); // use new ranks for next iteration
    }

    auto end = high_resolution_clock::now();
    handle_papi_error(
        PAPI_stop(EventSet, values),
        "PAPI_stop failed"
    );

    double elapsed = duration<double>(end - start).count();

    long long l1 = values[0];
    long long l2 = values[1];

    long long dram_near = values[2];
    long long dram_far = values[3];

    long long dram_fills = dram_near + dram_far;

    double checksum = 0.0;

    for (double value : pr) {
        checksum += value;
    }


    cout << "Total time in seconds: " << elapsed << " s\n";

    cout << "L1 DCM: " << l1 << "\n";

    cout << "L2 DCM: " << l2 << "\n";

    cout << "DRAM NEAR: " << dram_near << "\n";

    cout << "DRAM FAR: " << dram_far << "\n";

    cout << "DRAM FILLS: " << dram_fills << "\n";

    cout << "Checksum: " << checksum << "\n";

    handle_papi_error(
        PAPI_cleanup_eventset(EventSet),
        "PAPI_cleanup_eventset failed"
    );

    handle_papi_error(
        PAPI_destroy_eventset(&EventSet),
        "PAPI_destroy_eventset failed"
    );

    return 0;
}