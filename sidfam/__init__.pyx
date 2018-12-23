# distutils: language=c++
# cython: language_level = 3
from libcpp.unordered_set cimport unordered_set
from libcpp.vector cimport vector
from libcpp.utility cimport pair
from .automaton cimport Automaton as CAutomaton, \
    create_automaton, release_automaton, append_transition
from .path_graph cimport PathGraph as CPathGraph, create_path_graph, \
    _print_path_graph, release_path_graph, search_path
from .auto_group cimport AutoGroup as CAutoGroup, create_auto_group, \
    release_auto_group, append_automaton, build_path_graph, collect_path

__all__ = [
    'Automaton',
    'PathGraph',
    'Topo',
    'AutoGroup',
]

cdef class Automaton:
    cdef CAutomaton *c_automaton

    def __cinit__(self):
        # print('start create c_automaton')
        self.c_automaton = create_automaton()

    def __dealloc__(self):
        release_automaton(self.c_automaton)

    def _append_transition(
        self,
        int src_state, int dst_state,
        int guard, int require, int update,
        int next_hop
    ):
        append_transition(
            self.c_automaton,
            src_state, dst_state, guard, require, update, next_hop
        )

cdef class PathGraph:
    cdef CPathGraph *c_path_graph

    def __cinit__(
        self, Automaton automaton, Topo topo,
        int src_switch, int dst_switch
    ):
        self.c_path_graph = create_path_graph(
            automaton.c_automaton, src_switch, dst_switch,
            topo.c_topo[0], topo.c_switch_count
        )

    def __dealloc__(self):
        release_path_graph(self.c_path_graph)

    def _print(self):
        _print_path_graph(self.c_path_graph)

    # def search_path(self, max_depth=8):
    #     search_path(self.c_path_graph, max_depth)
    #     print(f'{self} searched {self.c_path_graph.path_list.size()} path(s)')

cdef extern from 'hash_pair.hpp':
    pass

cdef class Topo:
    cdef unordered_set[pair[int, int]] *c_topo
    cdef int c_switch_count
    cdef shortest_path_length_map

    def __cinit__(self):
        self.c_topo = NULL
        self.c_switch_count = 0

    def __init__(self, graph, shortest_path_length_map=None):
        self.c_topo = new unordered_set[pair[int, int]]()
        if self.c_topo == NULL:
            raise MemoryError()
        for src_switch, dst_switch in graph.edges:
            if src_switch >= self.c_switch_count:
                self.c_switch_count = src_switch + 1
            if dst_switch >= self.c_switch_count:
                self.c_switch_count = dst_switch + 1
            self.c_topo.insert(pair[int, int](src_switch, dst_switch))
        self.shortest_path_length_map = shortest_path_length_map

    def __dealloc__(self):
        if self.c_topo != NULL:
            del self.c_topo

cdef class AutoGroup:
    cdef CAutoGroup *c_auto_group
    cdef packet_class_list
    cdef vector[vector[int]] c_guard_dep, c_update_dep
    cdef int c_variable_count

    def __cinit__(self):
        self.c_auto_group = create_auto_group()

    def __init__(
        self, packet_class_list, guard_list, require_list, update_list
    ):
        self.packet_class_list = packet_class_list
        variable_map = {}
        self.c_guard_dep.resize(len(guard_list))
        self.c_update_dep.resize(len(update_list))
        for i, guard in enumerate(guard_list):
            for dep_var in guard.dep:
                if dep_var not in variable_map:
                    variable_map[dep_var] = len(variable_map)
                self.c_guard_dep[i].push_back(variable_map[dep_var])
        for i, update in enumerate(update_list):
            for dep_var in update.dep:
                if dep_var not in variable_map:
                    variable_map[dep_var] = len(variable_map)
                self.c_update_dep[i].push_back(variable_map[dep_var])
        self.c_variable_count = len(variable_map)

    def __dealloc__(self):
        release_auto_group(self.c_auto_group)

    def _append_automaton(
        self, Automaton automaton,
        int packet_class, int src_switch, int dst_switch
    ):
        append_automaton(
            self.c_auto_group, automaton.c_automaton,
            packet_class, src_switch, dst_switch
        )

    def __getitem__(self, packet_class_constr):
        class Helper:
            def __iadd__(_self, automaton):
                for i, packet_class in enumerate(self.packet_class_list):
                    if packet_class in packet_class_constr:
                        src_switch, dst_switch = packet_class.endpoints()
                        self._append_automaton(
                            automaton, i, src_switch, dst_switch
                        )

        return Helper()

    def __setitem__(self, _key, _value):
        pass

    def _build_path_graph(
        self, Topo topo, max_depth=12, adaptive_depth_range=5
    ):
        build_path_graph(self.c_auto_group, topo.c_topo, topo.c_switch_count)
        # print('after build')
        return Problem(
            self, max_depth,
            topo.shortest_path_length_map, adaptive_depth_range
        )

    def __matmul__(self, topo):
        return self._build_path_graph(topo)


cdef class Problem:
    cdef AutoGroup auto_group

    def __init__(
        self, AutoGroup auto_group, int max_depth,
        shortest_path_length_map, int adaptive_depth_range
    ):
        # print('inside Problem __init__')
        self.auto_group = auto_group
        collect_path(
            self.auto_group.c_auto_group,
            self.auto_group.c_guard_dep, self.auto_group.c_update_dep,
            self.auto_group.c_variable_count,
            max_depth,
            shortest_path_length_map, adaptive_depth_range
        )
        # print('exit')
