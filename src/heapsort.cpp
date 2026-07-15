#include <iostream>
#include <vector>
#include <chrono>
#include <random>
#include <algorithm>

using namespace std;
using namespace std::chrono;

// restore the heap property for the subtree rooted at index i
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

// sort the array in-place using heap sort
void heapSort(vector<int>& arr) {
    int n = static_cast<int>(arr.size());

    // build max-heap from the input array
    for(int i = n / 2 - 1; i >= 0; i--) {
        heapify(arr, n, i);
    }

    // extract elements from the heap one by one
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

    mt19937 rng(42);
    uniform_int_distribution<int> dist(0, 100'000'000);

    // generate a random input array
    vector<int> original(N);
    for(int i = 0; i < N; i++) {
        original[i] = dist(rng);
    }

    // run the benchmark multiple times and measure average execution time
    double totalTime = 0.0;
    for(int run = 0; run < numRuns; run++) {
        vector<int> arr = original;
        auto start = high_resolution_clock::now();
        heapSort(arr);
        auto end = high_resolution_clock::now();
        totalTime += duration<double>(end - start).count();
    }

    cout << "N: " << N << "\n";
    cout << "Average time over " << numRuns << " runs: "
         << (totalTime / numRuns) << " seconds\n";

    return 0;
}
