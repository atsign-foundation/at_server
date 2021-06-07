#!/usr/bin/python3
"""
Adds dependency overrides section in pubspec.yaml file for each project.
This is file is used in GITHub actions to resolve dependencies.
"""
import argparse
import ruamel.yaml
import copy

# Initialize parser
parser = argparse.ArgumentParser()
# Adding optional argument
parser.add_argument("-p", "--path")
parser.add_argument("-b", "--branch")

# Read arguments from command line
branch = parser.parse_args().branch
project_path = parser.parse_args().path


def add_dependency_overrides(project):
    with open(project + '/pubspec.yaml', 'r') as pubspec:
        yaml_map = ruamel.yaml.round_trip_load(pubspec, preserve_quotes=True)
    dependency_map = copy.deepcopy(yaml_map['dependencies'])

    for key, value in dependency_map.items():
        if key.startswith('at_') and 'at_server.git' in dependency_map[key]['git']['url']:
            dependency_map[key]['git']['ref'] = branch

    yaml_map['dependency_overrides'] = dependency_map

    with open(project + '/pubspec.yaml', 'w') as file:
        ruamel.yaml.round_trip_dump(yaml_map, file, explicit_start=True)
    file.close()


add_dependency_overrides(project_path)
