classdef DagNNTrainer < handle
    %DAGNNTRAINER implements a trainer for DagNN
    
    properties
        % independant
        props                           % properties of cnn (based on json file)
        db                              % database : struct('x', cell array, 'y', cell array)
        params_generator                % parameters generator (@rand, @randn, ...)
        backup_dir                      % directory of saving data for each epoch
        
        % dependant
        current_epoch                   % current epoch
        net                             % DagNN
        data                            % struct(...
                                        %   'train', struct('x', cell array, 'y', cell array), ...
                                        %   'val', struct('x', cell array, 'y', cell array), ...
                                        %   'test', struct('x', cell array, 'y', cell array) ...
                                        % )
        costs                           % stuct(...
                                        %   'train', double array, ...
                                        %   'val', double array, ...
                                        %   'test', double array ...
                                        % )
        elapsed_times                   % array of elased times
    end

    methods
        function obj = DagNNTrainer(dagnn_filename, db_filename)
            % props
            obj.init_props(dagnn_filename);

            % db
            obj.init_db(db_filename);

            % params_generator
            obj.params_generator = @rand;

            % backup_dir
            obj.backup_dir = './backup';
        end
        
        function init_props(obj, filename)
            % decode json
            obj.props = jsondecode(fileread(filename));
            
            % refine
            % - input
            obj.props.vars.input.size = obj.props.vars.input.size';
            
            % - output
            obj.props.vars.output.size = obj.props.vars.output.size';
            
            % - params
            for i = 1:length(obj.props.params)
                obj.props.params(i).size = obj.props.params(i).size';
            end
            
            % - layers
            for i = 1:length(obj.props.layers)
                % inputs
                if isempty(obj.props.layers(i).inputs)
                    obj.props.layers(i).inputs = {};
                else
                    obj.props.layers(i).inputs = obj.props.layers(i).inputs';
                end
                % outputs
                if isempty(obj.props.layers(i).outputs)
                    obj.props.layers(i).outputs = {};
                else
                    obj.props.layers(i).outputs = obj.props.layers(i).outputs';
                end
                
                % params
                if isempty(obj.props.layers(i).params)
                    obj.props.layers(i).params = {};
                else
                    obj.props.layers(i).params = obj.props.layers(i).params';
                end
            end
        end
        
        function init_db(obj, filename)
            % load db
            obj.db = getfield(load(filename), 'db'); 
        end
        
        function init_backup_dir(obj)
            if ~exist(obj.backup_dir, 'dir')
                mkdir(obj.backup_dir);
            end
        end
        
        function init_current_epoch(obj)
            list = dir(fullfile(obj.backup_dir, 'epoch_*.mat'));
            tokens = regexp({list.name}, 'epoch_([\d]+).mat', 'tokens');
            epoch = cellfun(@(x) sscanf(x{1}{1}, '%d'), tokens);
            obj.current_epoch = max(epoch);
        end
        
        function init_net(obj)
            if isempty(obj.current_epoch)
                obj.current_epoch = 0;
                % blocks
                blocks = struct(...
                    'conv', @dagnn.Conv, ...
                    'relu', @dagnn.ReLU, ...
                    'norm', @dagnn.NormOverall, ...
                    'sum', @dagnn.Sum, ...
                    'quadcost', @dagnn.QuadraticCost ...
                );

                % define object
                obj.net = dagnn.DagNN();
                % obj.net.conserveMemory = false;

                % add layers
                layers = obj.props.layers;
                for i = 1:length(layers)
                    obj.net.addLayer(...
                        layers(i).name, blocks.(layers(i).type)(), ...
                        layers(i).inputs, ...
                        layers(i).outputs, ...
                        layers(i).params ...
                    );
                end

                % init params
                obj.init_params();

                % set 'size' property of 'Conv' blocks
                for i = 1:length(obj.net.layers)
                    if isa(obj.net.layers(i).block, 'dagnn.Conv')
                        param_name = obj.net.layers(i).params{1};
                        param_index = obj.net.getParamIndex(param_name);
                        param_size = size(obj.net.params(param_index).value);

                        obj.net.layers(i).block.size = ...
                            horzcat(param_size, [1, 1]);
                    end
                end
                
                obj.save_net();
            else
                obj.load_net();
            end
        end
        
        function init_data(obj)
            % number of samples
            n = obj.props.number_of_samples;
            
            % ratios
            % - train
            ratios.train = obj.props.train_val_test_ratios(1);
            % - test
            ratios.val = obj.props.train_val_test_ratios(2);
            
            % shuffle db
            if exist(obj.get_db_indexes_filename(), 'file')
                indexes = obj.load_db_indexes();
            else
                indexes = randperm(n);
                obj.save_db_indexes(indexes);
            end
            
            % end index
            % - train
            end_index.train = floor(ratios.train * n);
            % - val
            end_index.val = floor((ratios.train + ratios.val) * n);
            % - test
            end_index.test = n;
            
            % data
            % - train
            % -- x
            obj.data.train.x = obj.db.x(indexes(1:end_index.train));
            % -- y
            obj.data.train.y = obj.db.y(indexes(1:end_index.train));
            
            % - val
            % -- x
            obj.data.val.x = obj.db.x(indexes(end_index.train + 1:end_index.val));
            % -- y
            obj.data.val.y = obj.db.y(indexes(end_index.train + 1:end_index.val));
            
            % - test
            % -- x
            obj.data.test.x = obj.db.x(indexes(end_index.val + 1:end_index.test));
            % -- y
            obj.data.test.y = obj.db.y(indexes(end_index.val + 1:end_index.test));
        end
        
        function init_params(obj)
            % INIT_PARAMS set obj.net.params
            params = obj.props.params;
            for i = 1:length(params)
                obj.net.params(obj.net.getParamIndex(params(i).name)).value = ...
                    obj.params_generator(params(i).size);
            end
        end
        
        function init_meta(obj)
            % INIT_META set obj.net.meta
            % meta = struct(...
            %       'input_name', string, ...
            %       'output_name', string, ...
            %       'expected_output_name', string, ...
            %       'cost_name', string, ...
            %       'train_val_test_ratios', [double, double, double], ...
            %       'number_of_samples', int, ...
            %       'learning_rate': double, ...
            %       'batch_size': int, ...
            %       'number_of_epochs': int, ...
            %       'number_of_val_fails': int, ...
            % )

            obj.net.meta = struct(...
                  'input_name', obj.props.vars.input.name, ...
                  'output_name', obj.props.vars.output.name, ...
                  'expected_output_name', obj.props.vars.expected_output.name, ...
                  'cost_name', obj.props.vars.cost.name, ...
                  'train_val_test_ratios', obj.props.train_val_test_ratios, ...
                  'number_of_samples', obj.props.number_of_samples, ...
                  'learning_rate', obj.props.learning_rate, ...
                  'batch_size', obj.props.batch_size, ...
                  'number_of_epochs', obj.props.number_of_epochs, ...
                  'number_of_val_fails', obj.props.number_of_val_fails ...
            );
        end
        
        function cost = get_cost(obj, x, y)
            n = length(x);
            cost = 0;
            for i = 1:n
                obj.net.eval(...
                    {...
                        obj.props.vars.input.name, x{i}, ...
                        obj.props.vars.expected_output.name, y{i} ...
                    } ...
                );

                cost = cost + obj.net.vars(...
                    obj.net.getVarIndex(obj.props.vars.cost.name) ...
                ).value;
            end
            
            cost = cost / n;
        end
        
        function train_cost = get_train_cost(obj)
            train_cost = ...
                obj.get_cost(obj.data.train.x, obj.data.train.y);
        end
        
        function val_cost = get_val_cost(obj)
            val_cost = ...
                obj.get_cost(obj.data.val.x, obj.data.val.y);
        end
        
        function test_cost = get_test_cost(obj)
            test_cost = ...
                obj.get_cost(obj.data.test.x, obj.data.test.y);
        end
        
        function init_costs(obj)
            if exist(obj.get_costs_filename(), 'file')
                obj.load_costs();
                obj.costs.train = ...
                    obj.costs.train(1:obj.current_epoch + 1);
                obj.costs.val = ...
                    obj.costs.val(1:obj.current_epoch + 1);
                obj.costs.test = ...
                    obj.costs.test(1:obj.current_epoch + 1);
            else
                % train costs
                obj.costs.train(1) = obj.get_train_cost();

                % val costs
                obj.costs.val(1) = obj.get_val_cost();

                % test costs
                obj.costs.test(1) = obj.get_test_cost();
                
                % save
                obj.save_costs();
            end
        end
        
        function init_elapsed_times(obj)
            if exist(obj.get_elapsed_times_filename(), 'file')
                obj.load_elapsed_times();
                obj.elapsed_times = ...
                    obj.elapsed_times(1:obj.current_epoch + 1);
            else
                obj.elapsed_times(1) = 0;
                obj.save_elapsed_times();
            end
        end
        
        function init(obj)
            % backup directory
            obj.init_backup_dir()

            % current epoch
            obj.init_current_epoch()

            % net
            obj.init_net();

            % data
            obj.init_data();

            % costs
            obj.init_costs();
            
            % elapsed times
            obj.init_elapsed_times();
        end
        
        function y = out(obj, x)
            n = length(x);
            y = cell(n, 1);
            for i = 1:n
                obj.net.eval(...
                    {obj.props.vars.input.name, x{i}} ...
                );

                y{i} = obj.net.vars(...
                    obj.net.getVarIndex(obj.props.vars.output.name) ...
                ).value;
            end
        end
        
        function make_db(obj, db_path, generator)
            % default generator
            if nargin < 2
                generator = @rand;
            end
            
            % make db
            % - x
            N = obj.props.number_of_samples;
            db.x = cell(N, 1);
            for i = 1:N
                obj.x{i} = generator(obj.props.vars.input.size);
            end
            
            % - y
            db.y = obj.out(db.x);
            
            % save db
            save(db_path, 'db');
            
            % delete db
            clear('db');
        end
        
        function draw_net(obj, face_alpha)
            if nargin == 1
                face_alpha = 0.8;
            end
            
            scales = obj.input_size;
            for i = 1:obj.L
                scales(end + 1, :) = obj.kernel_sizes(i, :);
                scales(end + 1, :) = obj.layers(i, :);
            end

            face_colors = zeros(size(scales, 1), 3);
            face_colors(1, :) = [1, 0, 0]; % x -> red
            face_colors(2:2:end, :) = repmat([0, 1, 0], obj.L, 1); % kernels -> green
            face_colors(3:2:end, :) = repmat([0, 0, 1], obj.L, 1); % layers -> blue
            
            CNN.draw_cubes(scales, face_colors, face_alpha);
        end
        
        function plot_kernel(obj, l)
            kd = KernelDesigner.load(obj.kernel_paths{l});
            kd.space_df.run();
            kd.time_df.run();
        end
        
        function plot_costs(obj)
            epochs = 1:length(obj.costs.train);
            epochs = epochs - 1; % start from zero (0, 1, 2, ...)
            
            figure(...
                'Name', 'CNN - Costs [Training, Validation, Test]', ...
                'NumberTitle', 'off', ...
                'Units', 'normalized', ...
                'OuterPosition', [0.25, 0.25, 0.5, 0.5] ...
            );
            
            % train
            plot(epochs, obj.costs.train, 'LineWidth', 2, 'Color', 'blue');
            set(gca, 'YScale', 'log');
            hold('on');
            % validation
            plot(epochs, obj.costs.val, 'LineWidth', 2, 'Color', 'green');
            % test
            plot(epochs, obj.costs.test, 'LineWidth', 2, 'Color', 'red');
            
            % minimum validation error
            % - circle
            [~, index_min_val_cost] = min(obj.costs.val);
            circle_x = index_min_val_cost - 1;
            circle_y = obj.costs.val(index_min_val_cost);
            dark_green = [0.1, 0.8, 0.1];
            scatter(circle_x, circle_y, ...
                'MarkerEdgeColor', dark_green, ...
                'SizeData', 300, ...
                'LineWidth', 2 ...
            );
            
            % - cross lines
            h_ax = gca;
            % -- horizontal line
            line(...
                h_ax.XLim, ...
                [circle_y, circle_y], ...
                'Color', dark_green, ...
                'LineStyle', ':', ...
                'LineWidth', 1.5 ...
            );
            % -- vertical line
            line(...
                [circle_x, circle_x], ...
                h_ax.YLim, ...
                'Color', dark_green, ...
                'LineStyle', ':', ...
                'LineWidth', 1.5 ...
            );
            
            hold('off');
            % labels
            xlabel('Epoch');
            ylabel('Mean Squared Error (mse)');
            
            % title
            title(...
                sprintf('Minimum Validation Error is %.3f at Epoch: %d', ...
                    obj.costs.val(index_min_val_cost), ...
                    index_min_val_cost - 1 ...
                    ) ...
            );
            
            % legend
            legend(...
                sprintf('Training (%.3f)', obj.costs.train(index_min_val_cost)), ...
                sprintf('Validation (%.3f)', obj.costs.val(index_min_val_cost)), ...
                sprintf('Test (%.3f)', obj.costs.test(index_min_val_cost)), ...
                'Best' ...
            );
            
            grid('on');
            grid('minor');
        end
        
        function run(obj)
            % init net
            obj.init();
            
            obj.current_epoch = obj.current_epoch + 1;
            
            % print epoch progress (epoch 0)
            obj.print_epoch_progress()
            
            % epoch number that network has minimum cost on validation data
            [~, index_min_val_cost] = min(obj.costs.val);
            
            n = length(obj.data.train.x);
            batch_size = obj.props.batch_size - 1;
            
            while obj.current_epoch <= obj.props.number_of_epochs
                begin_time = cputime();
                % shuffle train data
                permuted_indexes = randperm(n);
                for start_index = 1:batch_size:n
                    end_index = start_index + batch_size;
                    if end_index > n
                        end_index = n;
                    end
                    
                    indexes = permuted_indexes(start_index:end_index);
                    % make batch data
                    input = ...
                        DagNNTrainer.cell_array_to_tensor(...
                            obj.data.train.x(indexes) ...
                        );

                    expected_output = ...
                        DagNNTrainer.cell_array_to_tensor(...
                            obj.data.train.y(indexes) ...
                        );

                    % forwar, backward step
                    obj.net.eval(...
                        {...
                            obj.props.vars.input.name, input, ...
                            obj.props.vars.expected_output.name, expected_output
                        }, ...
                        {obj.props.vars.cost.name, 1} ...
                    );

                    % update step
                    for param_index = 1:length(obj.net.params)
                        obj.net.params(param_index).value = ...
                            obj.net.params(param_index).value - ...
                            obj.props.learning_rate * obj.net.params(param_index).der;
                    end
                    
                    % print samples progress
                    fprintf('Samples:\t%d-%d/%d\n', start_index, end_index, n);
                end
                
                % elapsed times
                obj.elapsed_times(end + 1) = cputime() - begin_time();
                % costs
                % - train
                obj.costs.train(end + 1) = obj.get_train_cost();
                % - val
                obj.costs.val(end + 1) = obj.get_val_cost();
                % - test
                obj.costs.test(end + 1) = obj.get_test_cost();
                
                % no imporovement in number_of_val_fails steps
                if obj.costs.val(end) < obj.costs.val(index_min_val_cost)
                    index_min_val_cost = length(obj.costs.val);
                end
                
                if (length(obj.costs.val) - index_min_val_cost) >= ...
                        obj.props.number_of_val_fails
                    break;
                end
                
                % print epoch progress
                obj.print_epoch_progress()

                % save
                % - costs
                obj.save_costs();
                % - elapsed times
                obj.save_elapsed_times();
                % - net
                obj.save_net();
                
                % increament current epoch
                obj.current_epoch = obj.current_epoch + 1;
            end
            
            % todo: load best validation performance
        end
        
        function filename = get_current_epoch_filename(obj)
            filename = fullfile(...
                obj.backup_dir, ...
                sprintf('epoch_%d', obj.current_epoch) ...
            );
        end
        
        function filename = get_costs_filename(obj)
            filename = fullfile(...
                obj.backup_dir, ...
                'costs.mat' ...
            );
        end
        
        function filename = get_elapsed_times_filename(obj)
            filename = fullfile(...
                obj.backup_dir, ...
                'elapsed_times.mat' ...
            );
        end
        
        function filename = get_db_indexes_filename(obj)
            filename = fullfile(...
                obj.backup_dir, ...
                'db_indexes.mat' ...
            );
        end
        
        function print_epoch_progress(obj)
            % Examples
            % --------
            % 1. 
            %   ```
            %   >>> obj.print_epoch_progress()
            %   --------------------------------
            %   Epoch:	...
            %   Costs:	[..., ..., ...]
            %   Time:	... s
            %   --------------------------------
            %   ```
            
            DagNNTrainer.print_dashline();
            fprintf('Epoch:\t%d\n', obj.current_epoch);
            fprintf('Costs:\t[%.3f, %.3f, %.3f]\n', ...
                obj.costs.train(end), ...
                obj.costs.val(end), ...
                obj.costs.test(end) ...
            );
            fprintf('Time:\t%f s\n', ...
                obj.elapsed_times(obj.current_epoch)); 
            DagNNTrainer.print_dashline();
        end
        
        function save_costs(obj)
            costs = obj.costs;
            
            save(...
                obj.get_costs_filename(), ...
                'costs' ...
            );
        
            clear('costs');
        end
        
        function load_costs(obj)
            obj.costs = getfield(...
                load(obj.get_costs_filename()), ...
                'costs' ...
            );
        end
        
        function save_elapsed_times(obj)
            elapsed_times = obj.elapsed_times;
            save(...
                obj.get_elapsed_times_filename(), ...
                'elapsed_times' ...
            );
        
            clear('elapsed_times');
        end
        
        function load_elapsed_times(obj)
            obj.elapsed_times = getfield(...
                load(obj.get_elapsed_times_filename()), ...
                'elapsed_times' ...
            );
        end
        
        function save_db_indexes(obj, indexes)
            db_indexes = indexes;
            save(...
                obj.get_db_indexes_filename(), ...
                'db_indexes' ...
            );
        end
        
        function db_indexes = load_db_indexes(obj)
            db_indexes = getfield(...
                load(obj.get_db_indexes_filename()), ...
                'db_indexes' ...
            );
        end
        
        function save_net(obj)
            net_struct = obj.net.saveobj();
            save(...
                obj.get_current_epoch_filename(), ...
                '-struct', 'net_struct' ...
            ) ;

            clear('net_struct');
        end
        
        function load_net(obj)
            net_struct = load(...
                obj.get_current_epoch_filename() ...
            ) ;

            obj.net = dagnn.DagNN.loadobj(net_struct) ;
            clear('net_struct');
        end
        
        function save(obj, filename)
            save(filename, 'obj');
        end
    end

    methods (Static)
        function tensor = cell_array_to_tensor(cell_array)
            tensor_size = horzcat(...
                size(cell_array{1}), ...
                [1, length(cell_array)] ...
            );
        
            indexes = cell(1, length(tensor_size));
            for i = 1:length(tensor_size)
                indexes{i} = 1:tensor_size(i);
            end
            
            tensor = zeros(tensor_size);
            for i = 1:length(cell_array)
                indexes{end} = i;
                tensor(indexes{:}) = cell_array{i};
            end
        end

        function make_db2(...
                db_path, ...
                number_of_samples, ...
                input_size, ...
                output_size, ...
                generator ...
        )
            %MAKEDB makes a db = struct('x', cell array, 'y', cell array)
            
            % default generator
            if nargin < 5
                generator = @rand;
            end
            
            % make db
            db.x = cell(number_of_samples, 1);
            db.y = cell(number_of_samples, 1);
        
            % - x, y
            for i = 1:number_of_samples
                db.x{i} = generator(input_size);
                db.y{i} = generator(output_size);
            end
            
            % save db
            save(db_path, 'db');
            
            % delete db
            clear('db');
        end
        
        function obj = load(filename)
            obj = load(filename);
            obj = obj.(char(fieldnames(obj)));
        end
        
        function print_dashline(length_of_line)
            % Examples
            % --------
            % 1.
            %   ```
            %   >>> DagNNTrainer.print_dashline(5)
            %   -----
            %   ```
            
            if nargin < 1
                length_of_line = 32;
            end
            
            fprintf(repmat('-', 1, length_of_line));
            fprintf('\n');
        end
        
        function dg = make_digraph(filename)
            % GET_DIGRAPH makes a directed-graph based on given 'json' file
            %
            % Parameters
            % ----------
            % - filename : char vector
            %   filename of input 'json' file
            %
            % Returns
            % - dg : digraph
            %   directed graph
            %
            % Examples
            % --------
            % 1. 
            %   >>> filename = './dagnn.json';
            %   >>> dg = DagNNTrainer.make_digraph(dagnn_filename);
            %   >>> dg.Edges
            %    EndNodes 
            %   __________
            %      ...
            
            % read 'json' file
            props = jsondecode(fileread(filename));
            
            % add layers to digraph
            dg = digraph();
            
            for l = 1 : length(props.layers)
                layer = props.layers(l);
                block = layer.name;
                
                % add edges
                % - inputs, block
                for i = 1 : length(layer.inputs)
                    x = layer.inputs(i);
                    dg = addedge(dg, x, block);
                end
                % - params, block
                for i = 1 : length(layer.params)
                    w = layer.params(i);
                    dg = addedge(dg, w, block);
                end
                % - block, outputs
                for i = 1 : length(layer.outputs)
                    y = layer.outputs(i);
                    dg = addedge(dg, block, y);
                end
            end
        end
        
        function plot_digraph(filename)
            % PLOT_DIGRAPH plot a directed-graph based on given 'json' file
            %
            % Parameters
            % ----------
            % - filename : char vector
            %   filename of input 'json' file
            %
            % Examples
            % --------
            % 1. 
            %   >>> filename = './dagnn.json';
            %   >>> dg = DagNNTrainer.plot_digraph(dagnn_filename);
            %   ...
            
            % read 'json' file
            props = jsondecode(fileread(filename)); 
            
            % make digraph
            dg = DagNNTrainer.make_digraph(filename);
            
            % plot graph
            h = plot(dg);
            
            % layout
            layout(h, 'layered', ...
                'Direction', 'right', ...
                'Sources', props.vars.input.name, ...
                'Sinks', props.vars.cost.name, ...
                'AssignLayers', 'asap' ...
            );
        
            % highlight
            % - input, output
            highlight(h, ...
                {props.vars.input.name, props.vars.expected_output.name}, ...
                'NodeColor', 'red' ...
            );
            % - params
            params = {};
            for i = 1 : length(props.params)
                params{end + 1} = props.params(i).name;
            end
            highlight(h, ...
                params, ...
                'NodeColor', 'green' ...
            );
            % - blocks
            ms = h.MarkerSize;
            blocks = {};
            for i = 1 : length(props.layers)
                blocks{end + 1} = props.layers(i).name;
            end
            highlight(h, ...
                blocks, ...
                'Marker', 's', ...
                'MarkerSize', 5 * ms ...
            );
            % hide axes
            set(h.Parent, ...
                'XTick', [], ...
                'YTick', [] ...
            );
            
        end
    end

end
