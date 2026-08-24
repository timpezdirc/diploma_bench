#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <string>

using namespace std;
using namespace std::chrono;

// perf stat control
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

    PerfController perf;

    perf.startMeasurement();
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
    perf.stopMeasurement();

    double elapsed = duration<double>(end - start).count();

    cout << "Total time in seconds: " << elapsed << " s\n";

    return 0;
}