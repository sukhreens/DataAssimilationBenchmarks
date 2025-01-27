import numpy as np
import seaborn as sns
import matplotlib.pyplot as plt
import pickle
from matplotlib.colors import Normalize
from matplotlib import rc
from matplotlib.colors import LogNorm
import glob
import ipdb
from matplotlib.colors import LogNorm
import h5py as h5

fig = plt.figure()
ax0 = fig.add_axes([.935, .085, .02, .830])
ax1a = fig.add_axes([.071, .085, .090, .25])
ax1b = fig.add_axes([.071, .375, .090, .25])
ax1c = fig.add_axes([.071, .665, .090, .25])
ax2a = fig.add_axes([.176, .085, .090, .25])
ax2b = fig.add_axes([.176, .375, .090, .25])
ax2c = fig.add_axes([.176, .665, .090, .25])
ax3a = fig.add_axes([.281, .085, .090, .25])
ax3b = fig.add_axes([.281, .375, .090, .25])
ax3c = fig.add_axes([.281, .665, .090, .25])
ax4a = fig.add_axes([.386, .085, .090, .25])
ax4b = fig.add_axes([.386, .375, .090, .25])
ax4c = fig.add_axes([.386, .665, .090, .25])
ax5a = fig.add_axes([.524, .085, .090, .25])
ax5b = fig.add_axes([.524, .375, .090, .25])
ax5c = fig.add_axes([.524, .665, .090, .25])
ax6a = fig.add_axes([.629, .085, .090, .25])
ax6b = fig.add_axes([.629, .375, .090, .25])
ax6c = fig.add_axes([.629, .665, .090, .25])
ax7a = fig.add_axes([.734, .085, .090, .25])
ax7b = fig.add_axes([.734, .375, .090, .25])
ax7c = fig.add_axes([.734, .665, .090, .25])
ax8a = fig.add_axes([.839, .085, .090, .25])
ax8b = fig.add_axes([.839, .375, .090, .25])
ax8c = fig.add_axes([.839, .665, .090, .25])

#method_list = ["enks-n-primal_classic", "enks-n-primal_single_iteration", "lin-ienks-n-transform", "ienks-n-transform"]
method_list = ["mles-n-transform_classic", "mles-n-transform_single_iteration", "lin-ienks-n-transform", "ienks-n-transform"]
#method_list = ["etks_classic", "etks_single_iteration", "lin-ienks-transform", "ienks-transform"]
stats = ["post", "filt", "fore"]
tanls = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50]
total_tanl = len(tanls)
mda = "false"
#mda = "true"
total_lag = 53
shift = 1

f = h5.File('processed_smoother_state_versus_tanl_diffusion_0.00_nanl_20000_burn_05000_mda_' +\
            mda + '_shift_' + str(shift).rjust(3, "0") + '.h5', 'r')

rmse_label_h_positions = [0.115, 0.220, 0.325, 0.430]
spread_label_h_positions = [0.570, 0.675, 0.780, 0.885]
label_v_positions = [0.336, 0.626, 0.916]

def find_optimal_values(method, stat, data):
    tuning_stat = 'fore'
    tuned_rmse = np.array(f[method + '_' + tuning_stat + '_rmse'])
    tuned_rmse_nan = np.isnan(tuned_rmse)
    tuned_rmse[tuned_rmse_nan] = np.inf
    tuned_rmse_min_vals = np.min(tuned_rmse, axis=1)
    tanl, lag = np.shape(tuned_rmse_min_vals)
    
    stat_rmse = np.array(f[method +'_' + stat + '_rmse'])
    stat_spread = np.array(f[method + '_' + stat + '_spread'])

    rmse_vals = np.zeros([tanl, lag])
    spread_vals = np.zeros([tanl, lag])

    for i in range(tanl):
        for j in range(lag):
            min_val = tuned_rmse_min_vals[i,j]
            indx = tuned_rmse[i,:,j] == min_val
            tmp_rmse = stat_rmse[i, indx, j]
            tmp_spread = stat_spread[i, indx, j]
            if len(tmp_rmse) > 1:
                tmp_rmse = tmp_rmse[0]
                tmp_spread = tmp_spread[0]

            rmse_vals[i,j] = tmp_rmse
            spread_vals[i,j] = tmp_spread
   
    rmse_vals = np.transpose(rmse_vals) 
    spread_vals = np.transpose(spread_vals)

    return [rmse_vals, spread_vals]

#color_map = sns.color_palette("husl", 101)
#color_map = sns.cubehelix_palette(80, rot=1.5, gamma=0.8, as_cmap=True)
color_map = sns.cubehelix_palette(80, start=.75, rot=1.50, reverse=True, dark=0.25)




max_scale = 1.00
min_scale = 0.00

rmse_ax_list = [ax1a, ax1b, ax1c, ax2a, ax2b, ax2c, ax3a, ax3b, ax3c, ax4a, ax4b, ax4c]
spread_ax_list = [ax5a, ax5b, ax5c, ax6a, ax6b, ax6c, ax7a, ax7b, ax7c, ax8a, ax8b, ax8c] 

i = 0
j = 0

for method in method_list:
    for stat in stats:
        if method[0:6] == "enks-n" or \
           method[0:6] == "mles-n" or \
           method[0:7] == "ienks-n" or \
           method[0:11] == "lin-ienks-n":
            rmse = np.transpose(np.array(f[method +'_' + stat + '_rmse']))
            spread = np.transpose(np.array(f[method +'_' + stat + '_spread']))
        else:
            rmse, spread = find_optimal_values(method, stat, f)

        sns.heatmap(rmse, linewidth=0.5, ax=rmse_ax_list[i], cbar_ax=ax0, vmin=min_scale, vmax=max_scale, cmap=color_map)
        sns.heatmap(spread, linewidth=0.5, ax=spread_ax_list[i], cbar_ax=ax0, vmin=min_scale, vmax=max_scale, cmap=color_map)

        if method == "etks_classic":
            scheme = "ETKS"

        elif method == "etks_single_iteration":
            scheme = "SIEnKS"

        elif method == "enks-n-primal_classic":
            scheme = "EnKS-N"

        elif method == "mles-n-transform_classic":
            scheme = "EnKS-N"

        elif method == "enks-n-primal_single_iteration":
            scheme = "SIEnKS-N"

        elif method == "mles-n-transform_single_iteration":
            scheme = "SIEnKS-N"

        elif method == "ienks-transform":
            scheme = "IEnKS"

        elif method == "lin-ienks-transform":
            scheme = "Lin-IEnKS"

        elif method == "ienks-n-transform":
            scheme = "IEnKS-N"

        elif method == "lin-ienks-n-transform":
            scheme = "Lin-IEnKS-N"

        plt.figtext(rmse_label_h_positions[j], label_v_positions[i % 3], scheme,  
                horizontalalignment='center', verticalalignment='bottom', fontsize=20)
        plt.figtext(spread_label_h_positions[j], label_v_positions[i % 3], scheme, 
                horizontalalignment='center', verticalalignment='bottom', fontsize=20)
        
        i += 1
    j += 1


x_labs = []
x_tics = []
x_vals = tanls
x_tic_vals = range(len(x_vals))
for i in range(len(x_vals)):
    if i % 4 == 0:
        x_labs.append(str(x_vals[i]))
        x_tics.append(x_tic_vals[i])

#x_labs.append(str(x_vals[-1]))
#x_tics.append(x_tic_vals[-1])

y_labs = []
y_tics =  []
y_vals = np.arange(1, total_lag, 3)
y_tic_vals = range(len(y_vals), 0, -1)
for i in range(len(y_vals)):
    if i % 3 == 0:
        y_labs.append(str(y_vals[i]))
        y_tics.append(y_tic_vals[i])

y_labs.append(str(y_vals[-1]))
y_tics.append(y_tic_vals[-1])

ax0.tick_params(
        labelsize=20)
ax1a.tick_params(
        labelsize=20)
ax1b.tick_params(
        labelsize=20,
        labelbottom=False)
ax1c.tick_params(
        labelsize=20,
        labelbottom=False)

ax2a.tick_params(
        labelsize=20,
        labelleft=False)
ax2b.tick_params(
        labelleft=False,
        labelbottom=False)
ax2c.tick_params(
        labelleft=False,
        labelbottom=False)

ax3a.tick_params(
        labelsize=20,
        labelleft=False)
ax3b.tick_params(
        labelleft=False,
        labelbottom=False)
ax3c.tick_params(
        labelleft=False,
        labelbottom=False)

ax4a.tick_params(
        labelsize=20,
        labelleft=False)
ax4b.tick_params(
        labelleft=False,
        labelbottom=False)
ax4c.tick_params(
        labelleft=False,
        labelbottom=False)

ax5a.tick_params(
        labelsize=20,
        labelleft=False)
ax5b.tick_params(
        labelleft=False,
        labelbottom=False)
ax5c.tick_params(
        labelleft=False,
        labelbottom=False)

ax6a.tick_params(
        labelsize=20,
        labelleft=False)
ax6b.tick_params(
        labelleft=False,
        labelbottom=False)
ax6c.tick_params(
        labelleft=False,
        labelbottom=False)

ax7a.tick_params(
        labelsize=20,
        labelleft=False)
ax7b.tick_params(
        labelleft=False,
        labelbottom=False)
ax7c.tick_params(
        labelleft=False,
        labelbottom=False)

ax8a.tick_params(
        labelsize=20,
        labelleft=False)
ax8b.tick_params(
        labelleft=False,
        labelbottom=False)
ax8c.tick_params(
        labelleft=False,
        labelbottom=False)

ax1a.set_yticks(y_tics)
ax1b.set_yticks(y_tics)
ax1c.set_yticks(y_tics)
ax2a.set_yticks(y_tics)
ax2b.set_yticks(y_tics)
ax2c.set_yticks(y_tics)
ax3a.set_yticks(y_tics)
ax3b.set_yticks(y_tics)
ax3c.set_yticks(y_tics)
ax4a.set_yticks(y_tics)
ax4b.set_yticks(y_tics)
ax4c.set_yticks(y_tics)
ax5a.set_yticks(y_tics)
ax5b.set_yticks(y_tics)
ax5c.set_yticks(y_tics)
ax6a.set_yticks(y_tics)
ax6b.set_yticks(y_tics)
ax6c.set_yticks(y_tics)
ax7a.set_yticks(y_tics)
ax7b.set_yticks(y_tics)
ax7c.set_yticks(y_tics)
ax8a.set_yticks(y_tics)
ax8b.set_yticks(y_tics)
ax8c.set_yticks(y_tics)

ax1a.set_xlim([0, total_tanl])
ax1b.set_xlim([0, total_tanl])
ax1c.set_xlim([0, total_tanl])
ax2a.set_xlim([0, total_tanl])
ax2b.set_xlim([0, total_tanl])
ax2c.set_xlim([0, total_tanl])
ax3a.set_xlim([0, total_tanl])
ax3b.set_xlim([0, total_tanl])
ax3c.set_xlim([0, total_tanl])
ax4a.set_xlim([0, total_tanl])
ax4b.set_xlim([0, total_tanl])
ax4c.set_xlim([0, total_tanl])
ax5a.set_xlim([0, total_tanl])
ax5b.set_xlim([0, total_tanl])
ax5c.set_xlim([0, total_tanl])
ax6a.set_xlim([0, total_tanl])
ax6b.set_xlim([0, total_tanl])
ax6c.set_xlim([0, total_tanl])
ax7a.set_xlim([0, total_tanl])
ax7b.set_xlim([0, total_tanl])
ax7c.set_xlim([0, total_tanl])
ax8a.set_xlim([0, total_tanl])
ax8b.set_xlim([0, total_tanl])
ax8c.set_xlim([0, total_tanl])
ax1a.set_xticks(x_tics)
ax1b.set_xticks(x_tics)
ax1c.set_xticks(x_tics)
ax2a.set_xticks(x_tics)
ax2b.set_xticks(x_tics)
ax2c.set_xticks(x_tics)
ax3a.set_xticks(x_tics)
ax3b.set_xticks(x_tics)
ax3c.set_xticks(x_tics)
ax4a.set_xticks(x_tics)
ax4b.set_xticks(x_tics)
ax4c.set_xticks(x_tics)
ax5a.set_xticks(x_tics)
ax5b.set_xticks(x_tics)
ax5c.set_xticks(x_tics)
ax6a.set_xticks(x_tics)
ax6b.set_xticks(x_tics)
ax6c.set_xticks(x_tics)
ax7a.set_xticks(x_tics)
ax7b.set_xticks(x_tics)
ax7c.set_xticks(x_tics)
ax8a.set_xticks(x_tics)
ax8b.set_xticks(x_tics)
ax8c.set_xticks(x_tics)
ax1a.set_yticklabels(y_labs, va="bottom", rotation=0)
ax1b.set_yticklabels(y_labs, va="bottom", rotation=0)
ax1c.set_yticklabels(y_labs, va="bottom", rotation=0)

ax8a.set_xticklabels(x_labs, rotation=0)
ax7a.set_xticklabels(x_labs, rotation=0)
ax6a.set_xticklabels(x_labs, rotation=0)
ax5a.set_xticklabels(x_labs, rotation=0)
ax4a.set_xticklabels(x_labs, rotation=0)
ax3a.set_xticklabels(x_labs, rotation=0)
ax2a.set_xticklabels(x_labs, rotation=0)
ax1a.set_xticklabels(x_labs, rotation=0)


if mda=="true":
    fig_title = r"MDA"

else:
    fig_title = r"SDA"


plt.figtext(.015, .52, r'$L$', horizontalalignment='center', verticalalignment='center', fontsize=22, rotation='90')
plt.figtext(.500, .225, r'Smoother', horizontalalignment='center', verticalalignment='center', fontsize=22, rotation='90')
plt.figtext(.500, .525, r'Filter', horizontalalignment='center', verticalalignment='center', fontsize=22, rotation='90')
plt.figtext(.500, .805, r'Forecast', horizontalalignment='center', verticalalignment='center', fontsize=22, rotation='90')
plt.figtext(.50, .015, r'$\Delta$t', horizontalalignment='center', verticalalignment='center', fontsize=22)
plt.figtext(.221, .025, r'RMSE', horizontalalignment='center', verticalalignment='center', fontsize=22)
plt.figtext(.725, .025, r'Spread', horizontalalignment='center', verticalalignment='center', fontsize=22)
plt.figtext(.5, .980, fig_title, horizontalalignment='center', verticalalignment='center', fontsize=22)


plt.show()
