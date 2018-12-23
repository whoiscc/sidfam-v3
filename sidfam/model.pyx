# distutils: language=c++
# cython: language_level = 3
from gurobipy import Model, GRB
from libcpp.vector cimport vector
from libcpp.utility cimport pair
from libcpp.unordered_map cimport unordered_map
from .auto_group cimport AutoGroup
from .path_graph cimport PathGraph

cdef extern from 'hash.hpp':
    pass

cdef create_model(
    vector[vector[int]] &model_path, AutoGroup *group, int switch_count,
    vector[vector[float]] &require_list,
    vector[unordered_map[pair[int, int], float]] &resource_list,
    vector[bint] &shared_resource,
    int packet_class_count
):
    model = Model()
    model_var = [None for _i in range(model_path.size())]

    cdef vector[unordered_map[  # switch
        pair[int, int],  # packet class & guard
        unordered_map[
            pair[int, int],  # update & next hop
            vector[pair[int, int]],  # path graph & path
        ]
    ]] distinguish
    distinguish.resize(switch_count)

    cdef vector[unordered_map[  # resource
        pair[int, int],  # source & destination
        vector[unordered_map[  # packet class
            pair[int, int],  # path graph & path
            float  # require
        ]]
    ]] require
    require.resize(resource_list.size())

    cdef int i = 0, path_index, j, node_index, previous_node_index, k
    cdef int res_index
    cdef float need
    cdef int current_hop, guard, update, next_hop, req
    cdef int packet_class
    cdef pair[int, int] dist_key, dist_action, dist_var, req_key, req_var
    cdef PathGraph *graph
    cdef vector[int] *path
    cdef int path_length
    print(f'model_path size: {model_path.size()}')
    print('scanning...')
    for graph_path in model_path:
        if graph_path.size() == 0:
            return None, None
        model_var[i] = [
            model.addVar(vtype=GRB.BINARY)
            for _i in range(graph_path.size())
        ]
        model.addConstr(sum(model_var[i]) == 1)

        packet_class = group.automaton_list.at(i).packet_class
        graph = group.path_graph_list.at(i)
        k = 0
        for path_index in graph_path:
            path = &graph.path_list.at(path_index)
            path_length = path.size()
            for j in range(1, path_length):
                previous_node_index = path.at(j - 1)
                node_index = path.at(j)
                current_hop = graph.node_list.at(previous_node_index).next_hop
                guard = graph.node_list.at(node_index).guard
                update = graph.node_list.at(node_index).update
                next_hop = graph.node_list.at(node_index).next_hop

                dist_key = pair[int, int](packet_class, guard)
                dist_action = pair[int, int](update, next_hop)
                dist_var = pair[int, int](i, k)

                if (distinguish[current_hop].count(dist_key) == 0):
                    distinguish[current_hop][dist_key] = unordered_map[
                        pair[int, int],  # update & next hop
                        vector[pair[int, int]],  # path graph & path
                    ]()
                if distinguish[current_hop][dist_key].count(dist_action) == 0:
                    distinguish[current_hop][dist_key][dist_action] = \
                        vector[pair[int, int]]()
                distinguish[current_hop][dist_key][dist_action].push_back(dist_var)

                req = graph.node_list.at(node_index).require
                req_key = pair[int, int](current_hop, next_hop)
                req_var = dist_var

                res_index = 0
                for need in require_list[req]:
                    if need == 0:
                        continue
                    # print(req_key)
                    assert resource_list[res_index].count(req_key) == 1
                    if require[res_index].count(req_key) == 0:
                        require[res_index][req_key] = vector[unordered_map[  # packet class
                            pair[int, int],  # path graph & path
                            float  # require
                        ]]()
                        require[res_index][req_key].resize(packet_class_count)
                    require[res_index][req_key][packet_class][req_var] = need

                    res_index += 1

            k += 1
        i += 1

    print('add distinguish constraints...')
    cdef unordered_map[
        pair[int, int],  # update & next hop
        vector[pair[int, int]],  # path graph & path
    ] key_dist
    cdef vector[pair[int, int]] action_dist
    cdef pair[int, int] var_index
    for switch_dist in distinguish:
        for _k, key_dist in switch_dist:
            # print(key_dist)
            choice_var_list = []
            for _k2, action_dist in key_dist:
                collected_var = []
                # print(action_dist)
                for var_index in action_dist:
                    collected_var.append(
                        model_var[var_index.first][var_index.second])
                choice_var = model.addVar(vtype=GRB.BINARY)
                model.addGenConstrMax(choice_var, collected_var)
                choice_var_list.append(choice_var)
            if len(choice_var_list) > 0:
                model.addConstr(sum(choice_var_list) <= 1)

    print('add require constraints...')
    cdef float amount
    cdef unordered_map[  # resource
        pair[int, int],  # source & destination
        vector[unordered_map[  # packet class
            pair[int, int],  # path graph & path
            float  # require
        ]]
    ] res_map
    cdef vector[unordered_map[  # packet class
        pair[int, int],  # path graph & path
        float  # require
    ]] req_map
    cdef unordered_map[  # packet class
        pair[int, int],  # path graph & path
        float  # require
    ] packet_class_req
    i = 0
    for res_map in require:
        for src_dst, req_map in res_map:
            amount = resource_list[i][src_dst]
            if shared_resource[i]:
                packet_class_reqiure_list = []
                for packet_class_req in req_map:
                    max_req = model.addVar(vtype=GRB.CONTINUOUS)
                    # print(var_index)
                    for var_index, need in packet_class_req:
                        model.addConstr(
                            model_var[var_index.first][var_index.second] * need \
                                <= max_req
                        )
                    packet_class_reqiure_list.append(max_req)
                model.addConstr(sum(packet_class_reqiure_list) <= amount)
        i += 1

    return model, model_var
