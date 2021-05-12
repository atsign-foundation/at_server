"""
Generates the config.yaml from the config-base.yaml
The default values in the configurations can be overridden by creating an
config-<environment>.properties file
The file accepts an optional parameter <environment>; defaults to production.
Example:
    Generating config.yaml for development.
        create an application properties file as 'config-development.properties'
        Run the generate_config.py passing 'development' as command line argument.
            python3 generate_config.py -e development
"""
import argparse
import yaml
from jproperties import Properties

# Initialize parser
parser = argparse.ArgumentParser()
# Adding optional argument
parser.add_argument("-e", "--env", default='production')

# Read arguments from command line
environment = parser.parse_args().env

# Read properties file
configs = Properties()
with open('config-' + environment + '.properties', 'rb') as read_prop:
    configs.load(read_prop)

with open("config-base.yaml", "r") as yamlfile:
    yamlMap = yaml.load(yamlfile, Loader=yaml.FullLoader)
    # Loop on each of the property in config properties.
    for key in configs.properties:
        fields = key.split('.')
        temp = yamlMap
        i = 0
        # Iterate into the map until the key is fetched.
        while i < len(fields):
            # Condition is to check if the key in the map is fetched.
            if i == len(fields) - 1:
                temp[fields[i]] = configs.properties[key]
                break
            temp = yamlMap[fields[i]]
            i = i + 1
    yamlfile.close()

# write to config file.
with open(r'config.yaml', 'w') as file:
    documents = yaml.dump(yamlMap, file)
    print('Generated the config file for ' + environment + ' environment')
