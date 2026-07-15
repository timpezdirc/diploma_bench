#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <cmath>

using namespace std;
using namespace std::chrono;

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
    auto duration = duration_cast<milliseconds>(end - start).count();

    cout << "Total time in seconds: " << duration / 1000.0 << " s\n";

    return 0;
}