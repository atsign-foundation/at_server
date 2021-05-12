import argparse
import yaml
from jproperties import Properties

# Initialize parser
parser = argparse.ArgumentParser()
# Adding optional argument
parser.add_argument("-e", "--env", default='prod')

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
            else:
                temp = yamlMap[fields[i]]
                i = i + 1
    yamlfile.close()

# write to config file.
with open(r'config.yaml', 'w') as file:
    documents = yaml.dump(yamlMap, file)
    print('Generated the config file for ' + environment + ' environment')
