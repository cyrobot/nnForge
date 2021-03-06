/*
 *  Copyright 2011-2013 Maxim Milakov
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#include "max_subsampling_2d_layer_hessian_cuda.h"

#include <cuda_runtime.h>

#include "util_cuda.h"
#include "neural_network_cuda_exception.h"

#include "../max_subsampling_layer.h"
#include "../nn_types.h"

struct __align__(4) window_x_x_config
{
	window_x_x_config(int window_x, int x)
	{
		this->window_x_x_pair = (((unsigned int)window_x) << 16) | (unsigned int)x;
	}

	unsigned int window_x_x_pair;
};

struct __align__(4) y_feature_map_config
{
	y_feature_map_config(int y, int feature_map_id)
	{
		this->y_feature_map_id_pair = (((unsigned int)y) << 16) | (unsigned int)feature_map_id;
	}

	unsigned int y_feature_map_id_pair;
};

struct __align__(4) x_y_config
{
	x_y_config(int x, int y)
	{
		this->x_y_pair = (((unsigned int)x) << 16) | (unsigned int)y;
	}

	unsigned int x_y_pair;
};

extern __shared__ float arr_sh[];

__global__ void max_subsampling_2d_tex_hess_kernel(
	float * __restrict output,
	x_y_config * __restrict max_positions,
	const float * __restrict input,
	const window_x_x_config * __restrict window_x_x_config_list,
	const y_feature_map_config * __restrict y_feature_map_config_list,
	int subsampling_width,
	int subsampling_height,
	int input_width,
	int input_height,
	int output_width,
	int output_height,
	int feature_map_count,
	int entry_count,
	int window_x_x_config_count,
	int y_feature_map_config_count)
{
	int window_x_x_config_id = blockIdx.x * blockDim.x + threadIdx.x;
	int feature_map_config_id = blockIdx.y * blockDim.y + threadIdx.y;
	int entry_id = blockIdx.z * blockDim.z + threadIdx.z;

	int local_thread_id = (threadIdx.z * blockDim.y + threadIdx.y) * blockDim.x + threadIdx.x;
	int threadblock_size = blockDim.z * blockDim.y * blockDim.x;

	float * vals = arr_sh;
	int * max_pos_y_list = (int *)(vals + threadblock_size);

	bool in_bounds = (entry_id < entry_count) && (window_x_x_config_id < window_x_x_config_count) && (feature_map_config_id < y_feature_map_config_count);

	float res = -1.0e37F;
	int max_pos_y;
	int window_x;
	int output_x;
	int output_y;
	int feature_map_id;
	if (in_bounds)
	{
		window_x_x_config wxx = window_x_x_config_list[window_x_x_config_id];
		output_x = wxx.window_x_x_pair & 0xFFFF;
		window_x = wxx.window_x_x_pair >> 16;

		y_feature_map_config yfm = y_feature_map_config_list[feature_map_config_id];
		feature_map_id = yfm.y_feature_map_id_pair & 0xFFFF;
		output_y = yfm.y_feature_map_id_pair >> 16;

		int input_x = output_x * subsampling_width + window_x;
		int input_y = output_y * subsampling_height;

		int current_input_elem_id = ((entry_id * feature_map_count + feature_map_id) * input_height + input_y) * input_width + input_x;

		res = input[current_input_elem_id];
		max_pos_y = 0;
		for(int j = 1; j < subsampling_height; ++j)
		{
			current_input_elem_id += input_width;
			float new_val = input[current_input_elem_id];
			if (new_val > res)
			{
				res = new_val;
				max_pos_y = j;
			}
		}

		vals[local_thread_id] = res;
		max_pos_y_list[local_thread_id] = max_pos_y;
	}

	__syncthreads();

	if (in_bounds && (window_x == 0))
	{
		int max_pos_x = 0;
		for(int j = 1; j < subsampling_width; ++j)
		{
			local_thread_id++;
			float new_val = vals[local_thread_id];
			int new_max_pos_y = max_pos_y_list[local_thread_id];

			if (new_val > res)
			{
				res = new_val;
				max_pos_x = j;
				max_pos_y = new_max_pos_y;
			}
		}
		int offset = ((entry_id * feature_map_count + feature_map_id) * output_height + output_y) * output_width + output_x;
		output[offset] = res;
		max_positions[offset].x_y_pair = (max_pos_x << 16) | max_pos_y;
	}
}

__global__ void max_subsampling_2d_square_deriviative_hess_kernel(
	float * __restrict input_errors,
	const x_y_config * __restrict max_positions,
	const float * __restrict output_errors,
	const x_y_config * __restrict x_y_config_list,
	int subsampling_width,
	int subsampling_height,
	int input_width,
	int input_height,
	int output_width,
	int output_height,
	int feature_map_count,
	int entry_count,
	int x_y_config_count)
{
	int x_y_config_id = blockIdx.x * blockDim.x + threadIdx.x;
	int feature_map_id = blockIdx.y * blockDim.y + threadIdx.y;
	int entry_id = blockIdx.z * blockDim.z + threadIdx.z;

	bool in_bounds = (entry_id < entry_count) && (x_y_config_id < x_y_config_count) && (feature_map_id < feature_map_count);

	if (in_bounds)
	{
		x_y_config xy = x_y_config_list[x_y_config_id];
		int output_x = xy.x_y_pair >> 16;
		int output_y = xy.x_y_pair & 0xFFFF;
		
		int offset = ((entry_id * feature_map_count + feature_map_id) * output_height + output_y) * output_width + output_x;

		float output_error = output_errors[offset];

		x_y_config max_pos_xy = max_positions[offset];
		int max_pos_x = max_pos_xy.x_y_pair >> 16;
		int max_pos_y = max_pos_xy.x_y_pair & 0xFFFF;

		int input_x = output_x * subsampling_width + max_pos_x;
		int input_y = output_y * subsampling_height + max_pos_y;

		int input_offset = ((entry_id * feature_map_count + feature_map_id) * input_height + input_y) * input_width + input_x;

		input_errors[input_offset] = output_error;
	}
}

namespace nnforge
{
	namespace cuda
	{
		max_subsampling_2d_layer_hessian_cuda::max_subsampling_2d_layer_hessian_cuda()
		{
		}

		max_subsampling_2d_layer_hessian_cuda::~max_subsampling_2d_layer_hessian_cuda()
		{
		}

		void max_subsampling_2d_layer_hessian_cuda::enqueue_test(
			cudaStream_t stream_id,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& data,
			const_cuda_linear_buffer_device_smart_ptr input_neurons_buffer,
			cuda_linear_buffer_device_smart_ptr output_neurons_buffer,
			const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
			unsigned int entry_count)
		{
			const float * input = *input_neurons_buffer;
			float * output = *output_neurons_buffer;
			x_y_config * max_positions = (x_y_config *)((void *)(*additional_buffers[0]));

			int window_x_x_config_count = subsampling_sizes[0] * output_configuration_specific.dimension_sizes[0];
			const window_x_x_config * window_x_x_config_list = static_cast<const window_x_x_config *>((const void *)*additional_buffers[1]);

			int y_feature_map_config_count = output_configuration_specific.dimension_sizes[1] * output_configuration_specific.feature_map_count;
			const y_feature_map_config * y_feature_map_config_list = static_cast<const y_feature_map_config *>((const void *)*additional_buffers[2]);

			std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
				*cuda_config,
				window_x_x_config_count,
				y_feature_map_config_count,
				entry_count,
				subsampling_sizes[0]);

			int threadblock_size = kernel_dims.second.x * kernel_dims.second.y * kernel_dims.second.z;
			int smem_size = threadblock_size * (sizeof(float) + sizeof(int));

			max_subsampling_2d_tex_hess_kernel<<<kernel_dims.first, kernel_dims.second, smem_size, stream_id>>>(
				output,
				max_positions,
				input,
				window_x_x_config_list,
				y_feature_map_config_list,
				subsampling_sizes[0],
				subsampling_sizes[1],
				input_configuration_specific.dimension_sizes[0],
				input_configuration_specific.dimension_sizes[1],
				output_configuration_specific.dimension_sizes[0],
				output_configuration_specific.dimension_sizes[1],
				output_configuration_specific.feature_map_count,
				entry_count,
				window_x_x_config_count,
				y_feature_map_config_count);
		}

		void max_subsampling_2d_layer_hessian_cuda::enqueue_backprop(
			cudaStream_t stream_id,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
			const std::vector<const_cuda_linear_buffer_device_smart_ptr>& data,
			const_cuda_linear_buffer_device_smart_ptr output_neurons_buffer,
			cuda_linear_buffer_device_smart_ptr output_errors_buffer,
			cuda_linear_buffer_device_smart_ptr input_errors_buffer,
			const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
			unsigned int entry_count)
		{
			cuda_util::set_with_value(
				*cuda_config,
				*input_errors_buffer,
				0.0F,
				input_elem_count_per_entry * entry_count,
				stream_id);

			const float * output_errors = *output_errors_buffer;
			const x_y_config * max_positions = (const x_y_config *)((void *)(*additional_buffers[0]));
			float * input_errors = *input_errors_buffer;

			int x_y_config_count = output_configuration_specific.dimension_sizes[0] * output_configuration_specific.dimension_sizes[1];
			const x_y_config * x_y_config_list = static_cast<const x_y_config *>((const void *)*additional_buffers[3]);

			std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
				*cuda_config,
				x_y_config_count,
				output_configuration_specific.feature_map_count,
				entry_count);

			max_subsampling_2d_square_deriviative_hess_kernel<<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(
				input_errors,
				max_positions,
				output_errors,
				x_y_config_list,
				subsampling_sizes[0],
				subsampling_sizes[1],
				input_configuration_specific.dimension_sizes[0],
				input_configuration_specific.dimension_sizes[1],
				output_configuration_specific.dimension_sizes[0],
				output_configuration_specific.dimension_sizes[1],
				output_configuration_specific.feature_map_count,
				entry_count,
				x_y_config_count);
		}

		void max_subsampling_2d_layer_hessian_cuda::hessian_configured()
		{
			nnforge_shared_ptr<const max_subsampling_layer> layer_derived = nnforge_dynamic_pointer_cast<const max_subsampling_layer>(layer_schema);

			subsampling_sizes = layer_derived->subsampling_sizes;
		}

		bool max_subsampling_2d_layer_hessian_cuda::is_in_place_backprop() const
		{
			return false;
		}

		std::vector<size_t> max_subsampling_2d_layer_hessian_cuda::get_sizes_of_additional_buffers_per_entry() const
		{
			std::vector<size_t> res;

			res.push_back(output_elem_count_per_entry * sizeof(x_y_config));

			return res;
		}

		std::vector<size_t> max_subsampling_2d_layer_hessian_cuda::get_sizes_of_additional_buffers_fixed() const
		{
			std::vector<size_t> res;

			res.push_back(sizeof(window_x_x_config) * subsampling_sizes[0] * output_configuration_specific.dimension_sizes[0]);
			res.push_back(sizeof(y_feature_map_config) * output_configuration_specific.dimension_sizes[1] * output_configuration_specific.feature_map_count);
			res.push_back(sizeof(x_y_config) * output_configuration_specific.dimension_sizes[1] * output_configuration_specific.dimension_sizes[0]);

			return res;
		}

		void max_subsampling_2d_layer_hessian_cuda::fill_additional_buffers(const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers) const
		{
			{
				std::vector<window_x_x_config> task_list;
				for(int x = 0; x < output_configuration_specific.dimension_sizes[0]; ++x)
					for(int window_x = 0; window_x < subsampling_sizes[0]; ++window_x)
						task_list.push_back(window_x_x_config(window_x, x));

				cuda_safe_call(cudaMemcpy(*additional_buffers[1], &(*task_list.begin()), sizeof(window_x_x_config) * task_list.size(), cudaMemcpyHostToDevice));
			}

			{
				std::vector<y_feature_map_config> task_list;
				for(int feature_map_id = 0; feature_map_id < output_configuration_specific.feature_map_count; ++feature_map_id)
					for(int y = 0; y < output_configuration_specific.dimension_sizes[1]; ++y)
						task_list.push_back(y_feature_map_config(y, feature_map_id));

				cuda_safe_call(cudaMemcpy(*additional_buffers[2], &(*task_list.begin()), sizeof(y_feature_map_config) * task_list.size(), cudaMemcpyHostToDevice));
			}

			{
				std::vector<x_y_config> task_list;
				for(int y = 0; y < output_configuration_specific.dimension_sizes[1]; ++y)
					for(int x = 0; x < output_configuration_specific.dimension_sizes[0]; ++x)
						task_list.push_back(x_y_config(x, y));

				cuda_safe_call(cudaMemcpy(*additional_buffers[3], &(*task_list.begin()), sizeof(x_y_config) * task_list.size(), cudaMemcpyHostToDevice));
			}
		}
	}
}
