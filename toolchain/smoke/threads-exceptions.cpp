#include <exception>
#include <iostream>
#include <stdexcept>
#include <thread>

int main() {
  try {
    throw std::runtime_error("WASIX C++ exception works");
  } catch (const std::exception &error) {
    std::cout << error.what() << '\n';
  }

  std::thread worker([] { std::cout << "WASIX pthread works\n"; });
  worker.join();
  return 0;
}
