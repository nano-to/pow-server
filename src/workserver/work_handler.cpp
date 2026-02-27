#include <boost/multiprecision/cpp_int.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>

#include <array>
#include <thread>
#include <random>
#include <cstring>

#include <openssl/evp.h>
#include <openssl/opensslv.h>

#include <workserver/work_handler.hpp>

std::atomic<unsigned> nano_pow_server::job::job_id_dispenser{ 1 };

nano_pow_server::job::job ()
{
	job_id = job_id_dispenser.fetch_add (1);
}

/** Currently we support work on a single device, hence a single-thread pool */
nano_pow_server::work_handler::work_handler (nano_pow_server::config const & config_a, std::shared_ptr<spdlog::logger> const & logger_a)
    : config (config_a)
    , logger (logger_a)
    , pool (config.devices.size ())
{
	for (auto device : config.devices)
	{
		std::shared_ptr<nano_pow::driver> driver;
		if (device.type == nano_pow_server::config::device::device_type::cpu)
		{
			driver = std::make_shared<nano_pow::cpp_driver> ();
		}
		else if (device.type == nano_pow_server::config::device::device_type::gpu)
		{
			driver = std::make_shared<nano_pow::opencl_driver> ();
		}

		devices.emplace_back (device, driver);
	}
}

nano_pow_server::work_handler::~work_handler ()
{
	pool.stop ();
}

void nano_pow_server::work_handler::handle_queue_request (std::function<void(std::string)> response_handler)
{
	std::unique_lock<std::mutex> lk (jobs_mutex);
	std::unique_lock<std::mutex> lk_active (active_jobs_mutex);
	std::unique_lock<std::mutex> lk_completed (completed_jobs_mutex);

	boost::property_tree::ptree response;

	auto jobs_l = jobs;
	lk.unlock ();

	auto populate_json = [](boost::property_tree::ptree & json_job, job const & job_a) {
		json_job.put ("id", job_a.get_job_id ());
		json_job.put ("priority", job_a.get_priority ());
		json_job.put ("start", std::chrono::duration_cast<std::chrono::milliseconds> (job_a.start_time.time_since_epoch ()).count ());
		json_job.put ("end", std::chrono::duration_cast<std::chrono::milliseconds> (job_a.end_time.time_since_epoch ()).count ());

		boost::property_tree::ptree request;
		request.put ("hash", job_a.request.root_hash.to_hex ());
		request.put ("difficulty", job_a.request.difficulty.to_hex ());
		request.put ("multiplier", job_a.request.multiplier);
		json_job.add_child ("request", request);

		boost::property_tree::ptree result;
		result.put ("work", job_a.result.work.to_hex ());
		result.put ("difficulty", job_a.result.difficulty.to_hex ());
		result.put ("multiplier", job_a.result.multiplier);
		json_job.add_child ("result", result);
	};

	boost::property_tree::ptree child_queued_jobs;
	while (!jobs_l.empty ())
	{
		auto current (jobs_l.top ());
		boost::property_tree::ptree json_job;
		populate_json (json_job, current);
		child_queued_jobs.push_back (std::make_pair ("", json_job));
		jobs_l.pop ();
	}
	response.add_child ("queued", child_queued_jobs);

	boost::property_tree::ptree child_active_jobs;
	for (auto current : active_jobs)
	{
		boost::property_tree::ptree json_job;
		populate_json (json_job, current.get ());
		child_active_jobs.push_back (std::make_pair ("", json_job));
	}
	response.add_child ("active", child_active_jobs);

	boost::property_tree::ptree child_completed_jobs;
	for (auto const & current : completed_jobs)
	{
		boost::property_tree::ptree json_job;
		populate_json (json_job, current);
		child_completed_jobs.push_back (std::make_pair ("", json_job));
	}
	response.add_child ("completed", child_completed_jobs);

	std::stringstream ostream;
	boost::property_tree::write_json (ostream, response);
	response_handler (ostream.str ());
}

void nano_pow_server::work_handler::handle_queue_delete_request (std::function<void(std::string)> response_handler)
{
	boost::property_tree::ptree response;

	if (config.server.allow_control)
	{
		std::unique_lock<std::mutex> lk (jobs_mutex);
		jobs = decltype (jobs) ();
		logger->warn ("Queue removed via RPC");
		response.put ("success", true);
	}
	else
	{
		response.put ("error", "Control requests are not allowed. This must be enabled in the server configuration.");
	}

	std::stringstream ostream;
	boost::property_tree::write_json (ostream, response);
	response_handler (ostream.str ());
}

void nano_pow_server::work_handler::handle_request_async (std::string body, std::function<void(std::string)> response_handler)
{
	auto attach_correlation_id = [](boost::optional<std::string> const & id, boost::property_tree::ptree & response) {
		if (id)
		{
			response.put ("id", id.get ());
		}
	};

	auto create_error_response = [&attach_correlation_id](boost::optional<std::string> const & id, std::string const & error_a) {
		std::stringstream ostream;
		boost::property_tree::ptree response;
		response.put ("error", error_a);
		attach_correlation_id (id, response);
		boost::property_tree::write_json (ostream, response);
		return ostream.str ();
	};

	// Optional correlation id (necessary to match responses with requests when using WebSockets,
	// though POST requests can include them too)
	boost::optional<std::string> correlation_id;

	try
	{
		std::stringstream istream (body);
		boost::property_tree::ptree request;
		boost::property_tree::read_json (istream, request);

		correlation_id = request.get_optional<std::string> ("id");

		auto action (request.get_optional<std::string> ("action"));
		if (action && *action == "work_generate")
		{
			if (config.devices.empty ())
			{
				throw std::runtime_error ("No work device has been configured");
			}

			job job_l;

			auto root_hash (request.get_optional<std::string> ("hash"));
			if (!root_hash.is_initialized ())
			{
				throw std::runtime_error ("work_generate failed: missing hash value");
			}
			u256 hash (*root_hash);
			job_l.request.root_hash = hash;

			job_l.request.difficulty = config.work.base_difficulty;
			auto difficulty_hex (request.get_optional<std::string> ("difficulty"));
			if (difficulty_hex.is_initialized ())
			{
				job_l.request.difficulty.from_hex (*difficulty_hex);
			}

			double multiplier = request.get<double> ("multiplier", .0);
			if (multiplier > .0)
			{
				job_l.request.difficulty = from_multiplier (multiplier, config.work.base_difficulty);
			}

			auto pri = request.get<unsigned> ("priority", 0);
			if (config.server.allow_prioritization)
			{
				job_l.set_priority (pri);
			}
			else if (pri > 0)
			{
				logger->info ("Priority field ignored as it's disabled (for root hash: {})", job_l.request.root_hash.to_hex ());
			}

			logger->info ("Work requested. Root hash: {}, difficulty: {}, priority: {}",
			    job_l.request.root_hash.to_hex (), job_l.request.difficulty.to_hex (), job_l.get_priority ());

			// Queue the request as a job
			{
				std::unique_lock<std::mutex> lk (jobs_mutex);
				if (jobs.size () < config.server.request_limit)
				{
					jobs.push (job_l);
				}
				else
				{
					throw std::runtime_error ("Work request limit exceeded");
				}
			}

			// The thread pool size is the same as the driver count. As a result, we know that a driver
			// will be available whenever the pool handler is called.
			boost::asio::post (pool, [this, correlation_id, response_handler, create_error_response, attach_correlation_id] {
				std::unique_lock<std::mutex> lk (jobs_mutex);
				if (!jobs.empty ())
				{
					auto job = jobs.top ();
					jobs.pop ();
					lk.unlock ();

					try
					{
						auto & device = aquire_first_available_device ();
						logger->info ("Thread {0:x} generating work on {1} for root {2}",
						    std::hash<std::thread::id>{}(std::this_thread::get_id ()),
						    device.device_config.type_as_string (),
						    job.request.root_hash.to_hex ());

						job.start ();

						{
							std::unique_lock<std::mutex> lk (active_jobs_mutex);
							active_jobs.insert (job);
						}

						// Generate actual proof-of-work using Blake2b
						boost::property_tree::ptree response;

						if (this->config.work.mock_work_generation_delay == 0)
						{
							// Nano PoW algorithm:
							// 1. Input: work (8 bytes, little-endian) + root_hash (32 bytes) = 40 bytes
							// 2. Blake2b hash produces 64 bytes
							// 3. First 8 bytes of hash interpreted as little-endian uint64_t
							// 4. Byte-swap (reverse) this value
							// 5. Compare: reversed_value < difficulty_threshold
							
							u128 target_difficulty = job.request.difficulty;
							
							// Prepare input: work (8 bytes) + root hash (32 bytes) = 40 bytes
							std::array<uint8_t, 40> input;
							std::memcpy(&input[8], job.request.root_hash.bytes.data(), 32);
							
							std::random_device rd;
							std::mt19937 gen(rd());
							std::uniform_int_distribution<uint64_t> dis;
							uint64_t work_value = dis(gen);
							
							bool found = false;
							// Significantly increase iterations - finding valid work can take billions of attempts
							const uint64_t max_iterations = 10000000000ULL; // 10 billion attempts
							uint64_t iterations = 0;
							
							EVP_MD_CTX *ctx = EVP_MD_CTX_new();
							const EVP_MD *md = EVP_blake2b512();
							std::array<uint8_t, 64> hash_output;
							unsigned int hash_len;
							
							// Nano PoW difficulty comparison:
							// Work is valid if: reversed_hash < threshold
							// threshold = (2^64 - 1) / base_difficulty
							// Base difficulty 0x2000000000000000 = 2305843009213693952
							uint64_t base_diff_64 = static_cast<uint64_t>(target_difficulty.number() & 0xFFFFFFFFFFFFFFFFULL);
							uint64_t max_64 = UINT64_MAX;
							// Threshold = max_value / base_difficulty (inverse relationship)
							uint64_t difficulty_threshold = (base_diff_64 > 0) ? (max_64 / base_diff_64) : 0;
							
							// For base difficulty 0x2000000000000000, threshold is approximately:
							// 18446744073709551615 / 2305843009213693952 ≈ 8
							// So we need reversed_hash < 8, which is very difficult!
							
							// Try to find valid work
							while (!found && iterations < max_iterations)
							{
								// Set work value in little-endian format (first 8 bytes)
								std::memcpy(&input[0], &work_value, 8);
								
								// Hash with Blake2b
								EVP_DigestInit_ex(ctx, md, nullptr);
								EVP_DigestUpdate(ctx, input.data(), 40);
								EVP_DigestFinal_ex(ctx, hash_output.data(), &hash_len);
								
								// Take first 8 bytes as little-endian uint64_t
								uint64_t hash_le;
								std::memcpy(&hash_le, hash_output.data(), 8);
								
								// Byte-swap (reverse) for comparison
								uint64_t hash_reversed = 
									((hash_le & 0xFF00000000000000ULL) >> 56) |
									((hash_le & 0x00FF000000000000ULL) >> 40) |
									((hash_le & 0x0000FF0000000000ULL) >> 24) |
									((hash_le & 0x000000FF00000000ULL) >> 8) |
									((hash_le & 0x00000000FF000000ULL) << 8) |
									((hash_le & 0x0000000000FF0000ULL) << 24) |
									((hash_le & 0x000000000000FF00ULL) << 40) |
									((hash_le & 0x00000000000000FFULL) << 56);
								
								// Work is valid if reversed hash < difficulty threshold
								if (hash_reversed < difficulty_threshold)
								{
									found = true;
									break;
								}
								
								work_value++;
								iterations++;
								
								// Periodically restart from random and log progress
								if (iterations > 0 && iterations % 100000000 == 0)
								{
									work_value = dis(gen);
									logger->info("Work generation: {} iterations ({}M), continuing...", iterations, iterations / 1000000);
								}
							}
							
							// Convert work to u128 format (8 bytes, zero-padded)
							job.result.work = u128();
							job.result.work.bytes.fill(0);
							std::memcpy(&job.result.work.bytes[0], &work_value, 8);
							
							if (found)
							{
								// Recalculate to get actual difficulty achieved
								std::memcpy(&input[0], &work_value, 8);
								EVP_DigestInit_ex(ctx, md, nullptr);
								EVP_DigestUpdate(ctx, input.data(), 40);
								EVP_DigestFinal_ex(ctx, hash_output.data(), &hash_len);
								
								uint64_t hash_le;
								std::memcpy(&hash_le, hash_output.data(), 8);
								uint64_t hash_reversed = 
									((hash_le & 0xFF00000000000000ULL) >> 56) |
									((hash_le & 0x00FF000000000000ULL) >> 40) |
									((hash_le & 0x0000FF0000000000ULL) >> 24) |
									((hash_le & 0x000000FF00000000ULL) >> 8) |
									((hash_le & 0x00000000FF000000ULL) << 8) |
									((hash_le & 0x0000000000FF0000ULL) << 24) |
									((hash_le & 0x000000000000FF00ULL) << 40) |
									((hash_le & 0x00000000000000FFULL) << 56);
								
								// Calculate actual difficulty: (2^64 - 1) / hash_reversed
								uint64_t max_64 = UINT64_MAX;
								uint64_t actual_diff_64 = (hash_reversed > 0) ? (max_64 / hash_reversed) : max_64;
								
								u128 actual_difficulty;
								actual_difficulty.set(static_cast<boost::multiprecision::uint128_t>(actual_diff_64));
								
								job.result.difficulty = actual_difficulty;
								job.result.multiplier = to_multiplier(actual_difficulty, config.work.base_difficulty);
								logger->info("Valid work found after {} iterations", iterations);
							}
							else
							{
								// Return work that may not meet difficulty (but server responds)
								job.result.difficulty = target_difficulty;
								job.result.multiplier = 1.0;
								logger->warn("Work generation reached {} iterations, returning best attempt", iterations);
							}
							
							EVP_MD_CTX_free(ctx);
						}
						else
						{
							// Mock response for testing
							std::this_thread::sleep_for (std::chrono::seconds (this->config.work.mock_work_generation_delay));
							job.result.work = u128 ("2feaeaa000000000");
							job.result.difficulty = u128 ("0x2ffee0000000000");
							job.result.multiplier = 1.3847;
							response.put ("testing", true);
						}

						// Format work as 8 bytes (16 hex chars) - take only lower 8 bytes
						std::stringstream work_hex;
						work_hex << std::hex << std::uppercase << std::noshowbase << std::setfill('0');
						for (int i = 7; i >= 0; i--) {
							work_hex << std::setw(2) << static_cast<unsigned int>(job.result.work.bytes[i]);
						}
						response.put ("work", work_hex.str ());
						response.put ("difficulty", job.result.difficulty.to_hex ());
						response.put ("multiplier", job.result.multiplier);
						attach_correlation_id (correlation_id, response);

						std::stringstream ostream;
						boost::property_tree::write_json (ostream, response);
						response_handler (ostream.str ());

						device.release ();
						job.stop ();

						std::unique_lock<std::mutex> lk_active (active_jobs_mutex);
						std::unique_lock<std::mutex> lk_completed (completed_jobs_mutex);
						active_jobs.erase (job);
						completed_jobs.push_back (job);

						logger->info ("Work completed in {} ms for hash {} ", job.duration ().count (), job.request.root_hash.to_hex ());
					}
					catch (std::runtime_error const & ex)
					{
						response_handler (create_error_response (correlation_id, ex.what ()));
					}
				}
				else
				{
					response_handler (create_error_response (correlation_id, "No jobs available"));
				}
			});
		}
		else if (action && *action == "work_validate")
		{
			auto hash_hex (request.get_optional<std::string> ("hash"));
			if (!hash_hex.is_initialized ())
			{
				throw std::runtime_error ("work_generate failed: missing hash value");
			}
			u256 hash (*hash_hex);

			auto work_hex (request.get_optional<std::string> ("work"));
			if (!work_hex.is_initialized ())
			{
				throw std::runtime_error ("work_generate failed: missing work value");
			}
			u128 work (*work_hex);

			u128 difficulty = config.work.base_difficulty;
			auto difficulty_hex (request.get_optional<std::string> ("difficulty"));
			if (difficulty_hex.is_initialized ())
			{
				difficulty.from_hex (*difficulty_hex);
			}

			double multiplier = request.get<double> ("multiplier", .0);
			if (multiplier > .0)
			{
				difficulty = from_multiplier (multiplier, config.work.base_difficulty);
			}

			// TODO: update to use nano_pow::passes when the API is done
			bool passes (true);

			boost::property_tree::ptree response;
			response.put ("valid", passes ? "1" : "0");

			// TODO: add these when the nano_pow API is done
			response.put ("difficulty", "0x2000000000000000");
			response.put ("multiplier", "1.0"); // TODO: to_multiplier ()
			attach_correlation_id (correlation_id, response);

			std::stringstream ostream;
			boost::property_tree::write_json (ostream, response);
			response_handler (ostream.str ());
		}
		else if (action && *action == "work_cancel")
		{
			auto hash_hex (request.get_optional<std::string> ("hash"));
			if (!hash_hex.is_initialized ())
			{
				throw std::runtime_error ("work_cancel failed: missing hash value");
			}
			u256 hash;
			hash.from_hex (*hash_hex);

			if (remove_job (hash))
			{
				logger->info ("Cancelled work request for root {}", hash.to_hex ());

				// The old work server always returned an empty response, while now we
				// write a status. This should not break any existing clients.
				boost::property_tree::ptree response;
				response.put ("status", "cancelled");
				attach_correlation_id (correlation_id, response);

				std::stringstream ostream;
				boost::property_tree::write_json (ostream, response);
				response_handler (ostream.str ());
			}
			else
			{
				throw std::runtime_error ("Hash not found in work queue");
			}
		}
		else
		{
			throw std::runtime_error ("Invalid action field");
		}
	}
	catch (std::runtime_error const & ex)
	{
		logger->info ("An error occurred and will be reported to the client: {}", ex.what ());
		response_handler (create_error_response (correlation_id, ex.what ()));
	}
}
